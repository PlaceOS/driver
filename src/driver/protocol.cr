require "json"
require "log"
require "set"
require "tasker"
require "tokenizer"

require "./protocol/request"

STDIN.blocking = false
STDIN.sync = false
STDERR.blocking = false
STDERR.sync = true
STDOUT.blocking = false
STDOUT.sync = true

class PlaceOS::Driver::Protocol
  Log = ::Log.for("driver.protocol")

  # NOTE:: potentially move to using https://github.com/jeromegn/protobuf.cr
  # 10_000 decodes
  # Proto decoding   0.020000   0.040000   0.060000 (  0.020322)
  # JSON decoding    0.140000   0.270000   0.410000 (  0.137979)
  # Should be a simple change.
  # Another option would be: https://github.com/Papierkorb/cannon
  # which should be even more efficient
  def initialize(input = STDIN, output = STDERR, timeout = 2.minutes)
    output.sync = false if output.responds_to?(:sync)
    @io = IO::Stapled.new(input, output, true)
    @write_lock = Mutex.new
    @tokenizer = ::Tokenizer.new do |io|
      begin
        io.read_bytes(Int32) + 4
      rescue
        0
      end
    end
    @callbacks = {
      start:     [] of Request -> Request?,
      stop:      [] of Request -> Request?,
      update:    [] of Request -> Request?,
      terminate: [] of Request -> Request?,
      exec:      [] of Request -> Request?,
      debug:     [] of Request -> Request?,
      ignore:    [] of Request -> Request?,
      info:      [] of Request -> Request?,
    }

    # Tracks request IDs that expect responses
    @tracking = {} of UInt64 => Channel(Request)

    # Send outgoing data
    @producer = ::Channel(Tuple(Request, Channel(Request)?)?).new(32)

    # Processes the incomming data
    @processor = ::Channel(Request).new(32)

    # Timout handler
    # Batched timeouts to reduce load. Any responses in these sets
    @current_requests = {} of UInt64 => Request
    @next_requests = {} of UInt64 => Request

    spawn(same_thread: true) { self.produce_io(timeout) }
    spawn(same_thread: true) { self.consume_io }
  end

  @timeouts : Tasker::Task? = nil

  def timeout(error, request)
    request.set_error(error)
    request.cmd = "result"
    @processor.send request
  end

  # For process manager
  def self.new_instance(input = STDIN, output = STDERR) : PlaceOS::Driver::Protocol
    @@instance = ::PlaceOS::Driver::Protocol.new(input, output)
  end

  def self.new_instance(instance : PlaceOS::Driver::Protocol) : PlaceOS::Driver::Protocol
    @@instance = instance
  end

  # For other classes
  def self.instance : PlaceOS::Driver::Protocol
    @@instance.not_nil!
  end

  def self.instance? : PlaceOS::Driver::Protocol?
    @@instance
  end

  def register(type, &block : Request -> Request?)
    @callbacks[type] << block
  end

  private def process!
    loop do
      message = @processor.receive?
      break unless message

      # Requests should run in async so they don't block the processing loop
      spawn(same_thread: true) { process(message.not_nil!) }
    end
    Log.debug { "protocol processor terminated" }
  end

  def process(message : Request)
    Log.debug { "protocol processing: #{message.inspect}" }
    callbacks = case message.cmd
                when "start"
                  # New instance of id == mod_id
                  # payload == module details
                  @callbacks[:start]
                when "stop"
                  # Stop instance of id
                  @callbacks[:stop]
                when "update"
                  # New settings for id
                  @callbacks[:update]
                when "terminate"
                  # Stop all the modules and exit the process
                  @callbacks[:terminate]
                when "exec"
                  # Run payload on id
                  @callbacks[:exec]
                when "debug"
                  # enable debugging on id
                  @callbacks[:debug]
                when "ignore"
                  # stop debugging on id
                  @callbacks[:ignore]
                when "info"
                  # return the number of running instances (for debugging purposes)
                  @callbacks[:info]
                when "result"
                  # result of an executed request
                  # seq == request id
                  # payload or error response
                  seq = message.seq
                  @current_requests.delete(seq)
                  @next_requests.delete(seq)
                  channel = @tracking.delete(seq)
                  channel.try &.send(message)
                  return
                else
                  raise "unknown request cmd type"
                end

    callbacks.each do |callback|
      response = callback.call(message)
      if response
        Log.debug { "protocol queuing response: #{response.inspect}" }
        @producer.send({response, nil})
        break
      end
    end
  rescue error
    message.payload = nil
    message.error = error.message
    message.backtrace = error.backtrace?
    Log.debug { "protocol queuing error response: #{message.inspect}" }
    @producer.send({message, nil})
  end

  def request(id, command, payload = nil, raw = false)
    req = Request.new(id.to_s, command.to_s)
    if payload
      req.payload = raw ? payload.to_s : payload.to_json
    end
    Log.debug { "protocol queuing request: #{req.inspect}" }

    begin
      @producer.send({req, nil})
    rescue ::Channel::ClosedError
      # This occurs on shutdown and can be ignored
    end

    req
  end

  def expect_response(id, reply_id, command, payload = nil, raw = false) : Channel(Request)
    req = Request.new(id, command.to_s, reply: reply_id)
    if payload
      req.payload = raw ? payload.to_s : payload.to_json
    end
    channel = Channel(Request).new(1)

    Log.debug { "protocol queuing request: #{req.inspect}" }
    @producer.send({req, channel})
    channel
  end

  @@seq = 0_u64
  INDICATOR = "\x00\x02"
  DELIMITER = "\x00\x03"

  private def produce_io(timeout_period)
    spawn(same_thread: true) { self.process! }

    # Ensures all outgoing event processing is done on the same thread
    spawn(same_thread: true) do
      @timeouts = Tasker.instance.every(timeout_period) do
        current_requests = @current_requests.values
        @current_requests = @next_requests
        @next_requests = {} of UInt64 => Request

        if !current_requests.empty?
          error = IO::TimeoutError.new("request timed out")
          current_requests.each do |request|
            timeout(error, request)
          end
        end
      end
    end

    # Process outgoing requests
    loop do
      begin
        req_data = @producer.receive?
        break unless req_data

        request, channel = req_data

        # Expects a response
        if channel
          seq = @@seq
          @@seq += 1
          request.seq = seq

          @tracking[seq] = channel
          @next_requests[seq] = request
        end

        Log.debug { "protocol sending (expects reply #{!!channel}): #{request.inspect}" }

        # Single call to write ensure there is no interlacing
        # in-case a 3rd party library writes something to STDERR
        @io.print(String.build { |msg|
          msg << INDICATOR
          request.to_json(msg)
          msg << DELIMITER
        })
        @io.flush
      rescue e
        Log.fatal { "Fatal error #{e.inspect_with_backtrace}" }
        exit(2)
      end
    end
  end

  # Reads IO off STDIN and extracts the request messages
  private def consume_io
    raw_data = Bytes.new(4096)

    # provide a ready signal
    @io.write_utf8("r".to_slice)
    @io.flush

    while !@io.closed?
      bytes_read = @io.read(raw_data)
      break if bytes_read == 0 # IO was closed

      Log.debug { "protocol received #{bytes_read}" }

      @tokenizer.extract(raw_data[0, bytes_read]).each do |message|
        string = nil
        begin
          string = String.new(message[4, message.bytesize - 4])
          Log.debug { "protocol queuing #{string}" }
          @processor.send Request.from_json(string)
        rescue error
          Log.warn(exception: error) { "error parsing request #{string.inspect}" }
        end
      end
    end
  rescue IO::Error
    # Input stream closed. This should only occur on termination
    Log.info { "IO terminated, exiting cleanly" }
  rescue e
    begin
      Log.fatal { e.inspect_with_backtrace }
    rescue
    end
    exit(1)
  ensure
    @producer.close
    @processor.close
    @timeouts.try &.cancel
  end
end
