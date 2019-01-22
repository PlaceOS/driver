require "json"
require "tokenizer"

class EngineDriver::Protocol
  # NOTE:: potentially move to using https://github.com/jeromegn/protobuf.cr
  # 10_000 decodes
  # Proto decoding   0.020000   0.040000   0.060000 (  0.020322)
  # JSON decoding    0.140000   0.270000   0.410000 (  0.137979)
  # Should be a simple change.
  class Request
    def initialize(@id, @cmd, @payload = nil, @error = nil, @backtrace = nil, @seq = nil)
    end

    # TODO:: add return address for replies (core routing)
    JSON.mapping(
      id: String,
      cmd: String,
      seq: UInt64?,
      payload: String?,
      error: String?,
      backtrace: Array(String)?
    )

    def set_error(error)
      self.payload = error.message
      self.error = error.class.to_s
      self.backtrace = error.backtrace?
      self
    end
  end

  def initialize(input = STDIN, output = STDERR)
    @io = IO::Stapled.new(input, output)
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
      result:    [] of Request -> Request?,
    }
    @tracking = {} of String => Channel::Buffered(Request)
    spawn { self.consume_io }
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
                  # id == request id
                  # payload or error response
                  @callbacks[:result]
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

  def expect_response(id, command, payload = nil, raw = false) : Channel::Buffered(Request)
    # TODO:: this requires a timeout
    seq = @@seq
    @@seq += 1

    req = Request.new(id, command.to_s, seq: seq)
    if payload
      req.payload = raw ? payload.to_s : payload.to_json
    end
    @tracking[id] = channel = Channel::Buffered(Request).new(1)

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
  end
end
