require "set"
require "json"
require "tasker"
require "tokenizer"
require "./protocol/request"

STDIN.blocking = false
STDIN.sync = true
STDERR.blocking = false
STDERR.sync = true
STDOUT.blocking = false
STDOUT.sync = true

class EngineDriver::Protocol
  # NOTE:: potentially move to using https://github.com/jeromegn/protobuf.cr
  # 10_000 decodes
  # Proto decoding   0.020000   0.040000   0.060000 (  0.020322)
  # JSON decoding    0.140000   0.270000   0.410000 (  0.137979)
  # Should be a simple change.
  def initialize(input = STDIN, output = STDERR, timeout = 2.minutes)
    @io = IO::Stapled.new(input, output, true)
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
    }

    # Tracks request IDs that expect responses
    @tracking = {} of UInt64 => Channel::Buffered(Request)

    # Timout handler
    # Batched timeouts to reduce load. Any responses in these sets
    @current_requests = {} of UInt64 => Request
    @next_requests = {} of UInt64 => Request
    @timeouts = Tasker.instance.every(timeout) do
      current_requests = @current_requests
      @current_requests = @next_requests
      @next_requests = {} of UInt64 => Request

      if !current_requests.empty?
        error = IO::Timeout.new("request timed out")
        current_requests.each_value do |request|
          spawn { timeout(error, request) }
        end
      end
    end

    spawn { self.consume_io }
  end

  @timeouts : Tasker::Task

  def timeout(error, request)
    request.set_error(error)
    request.cmd = "result"
    process(request)
  end

  # For process manager
  def self.new_instance(input = STDIN, output = STDERR) : EngineDriver::Protocol
    @@instance = ::EngineDriver::Protocol.new(input, output)
  end

  def self.new_instance(instance : EngineDriver::Protocol) : EngineDriver::Protocol
    @@instance = instance
  end

  # For other classes
  def self.instance : EngineDriver::Protocol
    @@instance.not_nil!
  end

  def self.instance? : EngineDriver::Protocol?
    @@instance
  end

  def register(type, &block : Request -> Request?)
    @callbacks[type] << block
  end

  def process(message)
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
        send(response)
        break
      end
    end
  rescue error
    message.payload = nil
    message.error = error.message
    message.backtrace = error.backtrace?
    send(message)
  end

  def request(id, command, payload = nil, raw = false)
    req = Request.new(id.to_s, command.to_s)
    if payload
      req.payload = raw ? payload.to_s : payload.to_json
    end
    send req
  end

  @@seq = 0_u64

  def expect_response(id, reply_id, command, payload = nil, raw = false) : Channel::Buffered(Request)
    seq = @@seq
    @@seq += 1

    req = Request.new(id, command.to_s, seq: seq, reply: reply_id)
    if payload
      req.payload = raw ? payload.to_s : payload.to_json
    end
    @tracking[seq] = channel = Channel::Buffered(Request).new(1)
    @next_requests[seq] = req

    send req
    channel
  end

  private def send(request)
    json = request.to_json
    @io.write_bytes json.bytesize
    @io.write json.to_slice
    request
  end

  # Reads IO off STDIN and extracts the request messages
  private def consume_io
    raw_data = Bytes.new(4096)

    while !@io.closed?
      bytes_read = @io.read(raw_data)
      break if bytes_read == 0 # IO was closed

      @tokenizer.extract(raw_data[0, bytes_read]).each do |message|
        string = nil
        begin
          string = String.new(message[4, message.bytesize - 4])
          request = Request.from_json(string)
          spawn { process(request) }
        rescue error
          puts "error parsing request #{string.inspect}\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
        end
      end
    end
  rescue IO::Error
  rescue Errno
    # Input stream closed. This should only occur on termination
  ensure
    @timeouts.cancel
  end
end
