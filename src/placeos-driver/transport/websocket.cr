require "simple_retry"
require "socket"

require "../transport"

class PlaceOS::Driver::TransportWebsocket < PlaceOS::Driver::Transport
  # timeouts in seconds
  def initialize(
    @queue : PlaceOS::Driver::Queue,
    @uri : String, @settings : ::PlaceOS::Driver::Settings,
    @headers_callback,
    &@received : (Bytes, PlaceOS::Driver::Task?) -> Nil
  )
    @terminated = false

    parts = URI.parse(@uri)
    @ip = parts.host.not_nil!
    @path = "#{parts.path}?#{parts.query}"
    @port = parts.port
    @use_tls = parts.scheme == "wss" || parts.scheme == "https"
    @tls = @use_tls ? new_tls_context : nil
  end

  @headers_callback : -> HTTP::Headers
  @ip : String
  @path : String
  @port : Int32?
  @use_tls : Bool
  @websocket : ConnectProxy::WebSocket?
  @tls : OpenSSL::SSL::Context::Client?
  property :received

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
    # Get dynamically defined headers
    headers = @headers_callback.call

    # Grab any pre-defined headers
    begin
      if header_hash = @settings.get { setting?(Hash(String, String | Array(String)), :headers) }
        header_hash.each { |key, value| headers[key] = value }
      end
    rescue error
      logger.info(exception: error) { "loading websocket headers" }
      nil
    end

    proxy = if proxy_config = @settings.get { setting?(NamedTuple(host: String, port: Int32, auth: NamedTuple(username: String, password: String)?), :proxy) }
              if !proxy_config[:host].empty?
                ConnectProxy.new(**proxy_config)
              end
            elsif ConnectProxy.behind_proxy?
              # Apply environment defined proxy
              begin
                ConnectProxy.new(*ConnectProxy.parse_proxy_url)
              rescue error
                logger.warn(exception: error) { "failed to apply environment proxy URI" }
                nil
              end
            end

    # Configure websocket to auto pong
    websocket = @websocket = ConnectProxy::WebSocket.new(@ip, @path, @port, @tls, headers, proxy)
    websocket.on_ping { |message| websocket.pong(message) }

    # Enable queuing
    @queue.online = true

    # Start consuming data from the socket
    spawn(same_thread: true) { consume_io }
  rescue error
    logger.info(exception: error) { "error connecting to device on #{@ip}:#{@port}#{@path}" }
    @queue.online = false
    raise error
  end

  def terminate : Nil
    @terminated = true
    @websocket.try &.close
  end

  def disconnect : Nil
    @websocket.try &.close
  rescue error
    logger.info(exception: error) { "calling disconnect" }
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

    case message
    when .is_a?(String | Bytes)
      websocket.send(message)
    when .responds_to? :to_io
      # TODO:: Resolve this once fixed in crystal lib
      # websocket.stream(true) { |io| io.write_bytes message }
      io = IO::Memory.new
      io.write_bytes message
      websocket.send(io.to_slice)
    when .responds_to? :to_slice
      websocket.send(message.to_slice)
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
      websocket.on_binary { |bytes| process bytes }
      websocket.on_message { |string| process string.to_slice }
      websocket.run
    end
  rescue IO::Error
  rescue error
    logger.error(exception: error) { "error consuming IO" }
  ensure
    disconnect
    @queue.online = false
    connect
  end
end
