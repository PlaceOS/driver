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

  private getter tracking : Hash(UInt64, Channel(Request))

  # Send outgoing data
  private getter producer : Channel(Tuple(Request, Channel(Request)?)?)

  # Processes the incomming data
  private getter processor : Channel(Request)

  # Timout handler
  # Batched timeouts to reduce load. Any responses in these sets
  private getter current_requests : Hash(UInt64, Request)
  private getter next_requests : Hash(UInt64, Request)

  getter process_manager : PlaceOS::Driver::ProcessManagerInterface

  # NOTE:: potentially move to using https://github.com/jeromegn/protobuf.cr
  # 10_000 decodes
  # Proto decoding   0.020000   0.040000   0.060000 (  0.020322)
  # JSON decoding    0.140000   0.270000   0.410000 (  0.137979)
  # Should be a simple change.
  # Another option would be: https://github.com/Papierkorb/cannon
  # which should be even more efficient
  def initialize(input = STDIN, output = STDERR, timeout = 2.minutes, logger_io = ::PlaceOS::Driver.logger_io, edge_driver : Bool = false, process_manager : PlaceOS::Driver::ProcessManagerInterface? = nil)
    @process_manager = process_manager || PlaceOS::Driver::ProcessManager.new(
      logger_io: logger_io,
      input: input,
      edge_driver: edge_driver
    )
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
  def self.new_instance(input = STDIN, output = STDERR, timeout = 2.minutes, logger_io = ::PlaceOS::Driver.logger_io, edge_driver : Bool = false, process_manager : PlaceOS::Driver::ProcessManagerInterface? = nil) : PlaceOS::Driver::Protocol
    @@instance = ::PlaceOS::Driver::Protocol.new(input, output, timeout, logger_io, edge_driver, process_manager)
  end

  def self.new_instance(instance : PlaceOS::Driver::Protocol) : PlaceOS::Driver::Protocol
    @@instance = instance
  end

  # For other classes
  class_getter! instance : PlaceOS::Driver::Protocol?

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

    spawn(same_thread: true) { dispatch_request(message) }
  end

  protected def dispatch_request(message)
    response = case message.cmd
               in .exec?
                 @process_manager.exec(message)
               in .info?
                 @process_manager.info(message)
               in .update?
                 @process_manager.update(message)
               in .start?
                 @process_manager.start(message)
               in .stop?
                 @process_manager.stop(message)
               in .terminate?
                 @process_manager.terminate
               in .debug?
                 @process_manager.debug(message)
               in .ignore?
                 @process_manager.ignore(message)
               in .sys?, .setting?, .hset?, .set?, .clear?, .publish?, .result?, .exited?
                 # these are not expected
               end

    if response
      Log.debug { "protocol queuing response: #{response.inspect}" }
      @producer.send({response, nil})
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
    spawn { self.redis_health_check }

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
    io.write_string("r".to_slice)
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

  private def redis_health_check
    failures = 0
    loop do
      return if @process_manager.terminated.closed?

      time = (50 + rand(10)).seconds
      select
      when @process_manager.terminated.receive?
        return
      when timeout(time)
        # perform health check
        begin
          ::PlaceOS::Driver::RedisStorage.with_redis(&.ping)
          failures = 0
        rescue error
          failures += 1
          raise error if failures >= 2
          Log.warn(exception: error) { "redis healthcheck failed - retrying" }
        end
      end
    end
  rescue error
    Log.fatal(exception: error) { "redis healthcheck failed - terminating process" }
    @process_manager.terminate
  end
end
