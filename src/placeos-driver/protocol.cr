require "json"
require "log"
require "set"
require "tasker"
require "tokenizer"

require "./protocol/request"

STDIN.blocking = false
STDIN.sync = false

STDERR.flush_on_newline = false
STDERR.blocking = false
STDERR.sync = true # we mark this as false if in use for protocol comms

STDOUT.blocking = false
STDOUT.sync = true

# :nodoc:
class PlaceOS::Driver::Protocol
  Log = ::Log.for(self)

  getter callbacks : Hash(Request::Command, Array(Request -> Request?)) do
    Hash(Request::Command, Array(Request -> Request?)).new(Request::Command.values.size) do |h, k|
      h[k] = [] of Request -> Request?
    end
  end

  private getter tracking : Hash(UInt64, Channel(Request))

  # Send outgoing data
  private getter producer : Channel(Tuple(Request, Channel(Request)?)?)

  # Processes the incomming data
  private getter processor : Channel(Request)

  # Timout handler
  # Batched timeouts to reduce load. Any responses in these sets
  private getter current_requests : Hash(UInt64, Request)
  private getter next_requests : Hash(UInt64, Request)

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
    @tokenizer = ::Tokenizer.new do |io|
      begin
        io.read_bytes(Int32) + 4
      rescue
        0
      end
    end

    # Tracks request IDs that expect responses
    @tracking = {} of UInt64 => Channel(Request)

    # Send outgoing data
    @producer = ::Channel(Tuple(Request, Channel(Request)?)?).new

    # Processes the incomming data
    @processor = ::Channel(Request).new(1)

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
    request.cmd = :result
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
  class_getter! instance : PlaceOS::Driver::Protocol?

  def register(type : Request::Command, &block : Request -> Request?)
    callbacks[type] << block
  end

  private def process!
    while message = @processor.receive?
      process(message)
    end
    Log.debug { "protocol processor terminated" }
  end

  def process(message : Request) : Nil
    Log.debug { "protocol processing: #{message.inspect}" }
    if message.cmd.result?
      # result of an executed request
      # seq == request id
      # payload or error response
      seq = message.seq
      @current_requests.delete(seq)
      @next_requests.delete(seq)
      if channel = @tracking.delete(seq)
        # non-blocking, channel is of size 1
        begin
          channel.send(message) unless channel.closed?
        rescue
          # ignore any error here as possible for the channel to timeout
          # this rescue is overzealous unless running in multi-threaded mode
        end
      end
      return
    end

    if watching = callbacks[message.cmd]?
      spawn(same_thread: true) { call_watchers(watching, message) }
    end
  end

  protected def call_watchers(watching, message)
    watching.each do |callback|
      if response = callback.call(message)
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

  def request(id, command : Request::Command, payload = nil, raw = false, user_id = nil)
    req = Request.new(id.to_s, command, user_id: user_id)
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

  def expect_response(id, reply_id, command : Request::Command, payload = nil, raw = false, user_id = nil) : Channel(Request)
    req = Request.new(id, command, reply: reply_id, user_id: user_id)
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
    @timeouts = Tasker.every(timeout_period) do
      current_requests = @current_requests.values
      @current_requests = @next_requests
      @next_requests = {} of UInt64 => Request

      if !current_requests.empty?
        error = IO::TimeoutError.new("request timed out")
        current_requests.each { |request| timeout(error, request) }
      end
    end

    # Process outgoing requests
    begin
      io = @io
      while req_data = @producer.receive?
        request, channel = req_data
        write_request(io, request, channel)
      end
    rescue e
      Log.fatal { "Fatal error #{e.inspect_with_backtrace}" }
      exit(2)
    end
  end

  protected def write_request(io, request, channel)
    # Expects a response
    if channel
      seq = @@seq
      @@seq += 1
      request.seq = seq

      @tracking[seq] = channel
      @next_requests[seq] = request
    end

    Log.debug { "protocol sending (expects reply #{!!channel}): #{request.inspect}" }

    io << INDICATOR
    request.to_json(io)
    io << DELIMITER
    io.flush
  end

  # Reads IO off STDIN and extracts the request messages
  private def consume_io
    raw_data = Bytes.new(4096)
    io = @io

    # provide a ready signal
    {% if compare_versions(Crystal::VERSION, "1.1.1") <= 0 %}
      io.write_utf8("r".to_slice)
    {% else %}
      io.write_string("r".to_slice)
    {% end %}
    io.flush

    until io.closed? || (bytes_read = io.read(raw_data)).nil? || bytes_read.zero?
      Log.debug { "protocol received #{bytes_read}" }

      @tokenizer.extract(raw_data[0, bytes_read]).each do |message|
        string = String.new(message[4, message.bytesize - 4])
        begin
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
