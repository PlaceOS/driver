require "simple_retry"
require "socket"

class PlaceOS::Driver::TransportWebsocket < PlaceOS::Driver::Transport
  # timeouts in seconds
  def initialize(@queue : PlaceOS::Driver::Queue, @uri : String, @settings : ::PlaceOS::Driver::Settings, &@received : (Bytes, PlaceOS::Driver::Task?) -> Nil)
    @terminated = false
    @logger = @queue.logger

    parts = URI.parse(@uri)
    @ip = parts.host.not_nil!
    @path = "#{parts.path}?#{parts.query}"
    @port = parts.port
    @use_tls = parts.scheme == "wss" || parts.scheme == "https"
    @tls = @use_tls ? new_tls_context : nil
  end

  @ip : String
  @path : String
  @port : Int32?
  @use_tls : Bool
  @logger : ::Logger
  @websocket : HTTP::WebSocket?
  @tls : OpenSSL::SSL::Context::Client?
  property :received
  getter :logger

  def connect(connect_timeout : Int32 = 10) : Nil
    return if @terminated
    if websocket = @websocket
      return unless websocket.closed?
    end

    # Clear any buffered data before we re-connect
    tokenizer = @tokenizer
    tokenizer.clear if tokenizer

    SimpleRetry.try_to(
      base_interval: 1.second,
      max_interval: 10.seconds,
      randomise: 500.milliseconds
    ) do
      start_socket(connect_timeout)
    end
  end

  private def start_socket(connect_timeout)
    # Grab any pre-defined headers
    header_hash = @settings.get { setting(Hash(String, String | Array(String))?, :headers) }
    websocket = if header_hash
                  headers = HTTP::Headers.new
                  header_hash.each do |key, value|
                    headers[key] = value
                  end
                  @websocket = HTTP::WebSocket.new(@ip, @path, @port, @tls, headers)
                else
                  @websocket = HTTP::WebSocket.new(@ip, @path, @port, @tls)
                end

    # Auto pong
    websocket.on_ping { |message| websocket.pong(message) }

    # Enable queuing
    @queue.online = true

    # Start consuming data from the socket
    spawn(same_thread: true) { consume_io }
  rescue error
    @logger.info { "connecting to device\n#{error.inspect_with_backtrace}" }
    @queue.online = false
    raise error
  end

  def terminate : Nil
    @terminated = true
    @websocket.try &.close
  end

  def disconnect : Nil
    @websocket.try &.close
  end

  def start_tls(verify_mode = OpenSSL::SSL::VerifyMode::NONE, context = @tls) : Nil
    tls = context || OpenSSL::SSL::Context::Client.new
    tls.verify_mode = verify_mode
    @tls = tls

    # Forces use of this TLS
    disconnect
  end

  def send(message) : PlaceOS::Driver::TransportWebsocket
    websocket = @websocket
    return self if websocket.nil? || websocket.closed?

    if message.is_a?(String)
      websocket.send(message)
    elsif message.is_a?(Bytes)
      websocket.send(message)
    elsif message.responds_to? :to_io
      # TODO:: Resolve this once fixed in crystal lib
      # websocket.stream(true) { |io| io.write_bytes message }
      io = IO::Memory.new
      io.write_bytes message
      websocket.send(io.to_slice)
    elsif message.responds_to? :to_slice
      data = message.to_slice
      websocket.send(data)
    else
      websocket.send(message)
    end

    self
  end

  def send(message, task : PlaceOS::Driver::Task, &block : (Bytes, PlaceOS::Driver::Task) -> Nil) : PlaceOS::Driver::TransportWebsocket
    task.processing = block
    send(message)
  end

  def ping(message = nil)
    @websocket.try &.ping(message)
  end

  def pong(message = nil)
    @websocket.try &.pong(message)
  end

  private def consume_io
    if websocket = @websocket
      websocket.on_binary { |bytes| spawn(same_thread: true) { process bytes } }
      websocket.on_message { |string| spawn(same_thread: true) { process string.to_slice } }
      websocket.run
    end
  rescue IO::Error | Errno
  rescue error
    @logger.error "error consuming IO\n#{error.inspect_with_backtrace}"
  ensure
    @queue.online = false
    connect
  end
end
