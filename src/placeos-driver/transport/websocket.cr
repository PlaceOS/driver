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

  @connect_lock : Mutex = Mutex.new
  @connection_state_changing : Bool = false
  # incremented each time a new socket is established so delayed disconnect
  # fibers can detect their socket has already been replaced
  @generation : UInt64 = 0_u64
  @headers_callback : -> HTTP::Headers
  @ip : String
  @path : String
  @port : Int32?
  @use_tls : Bool
  @websocket : ConnectProxy::WebSocket?
  @tls : OpenSSL::SSL::Context::Client?
  property :received

  def connect(connect_timeout : Int32 = 10) : Nil
    @connect_lock.synchronize do
      return if @terminated || @connection_state_changing
      @connection_state_changing = true
    end

    # the cleanup must only run once this fiber owns the state change,
    # otherwise an early return here would clear the flag set by another
    # connect and tear down the connection that fiber is mid-establishing
    begin
      if websocket = @websocket
        unless websocket.closed?
          # a healthy socket already exists, re-assert the connected state in
          # case a delayed disconnect marked the queue offline after this
          # socket was established
          set_connected_state(true)
          return
        end
      end

      # Clear any buffered data before we re-connect
      tokenizer = @tokenizer
      tokenizer.clear if tokenizer

      SimpleRetry.try_to(
        base_interval: 1.second,
        max_interval: 10.seconds,
        randomise: 500.milliseconds
      ) do
        start_socket(connect_timeout) unless @terminated
      end
    ensure
      @connect_lock.synchronize { @connection_state_changing = false }
      disconnect if @terminated || @websocket.nil? || @websocket.try(&.closed?)
    end
  end

  private def start_socket(connect_timeout)
    # Get dynamically defined headers
    headers = @headers_callback.call

    # Grab any pre-defined headers
    begin
      if header_hash = @settings.get { setting?(Hash(String, String | Array(String)), :headers) }
        header_hash.each do |key, value|
          case value
          in String
            headers[key] = value
          in Array(String)
            headers[key] = value
          end
        end
      end
    rescue error
      logger.info(exception: error) { "loading websocket headers" }
      nil
    end

    proxy = if proxy_config = @settings.get { setting?(NamedTuple(host: String, port: Int32, auth: NamedTuple(username: String, password: String)?), :proxy) }
              if proxy_config[:host].presence
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
    @proxy_in_use = proxy.try &.proxy_host

    # configure websocket
    websocket = @websocket = ConnectProxy::WebSocket.new(@ip, @path, @port, @tls, headers, proxy, ignore_env: true)
    generation = @generation &+= 1

    # Enable queuing
    set_connected_state(true)

    # Start consuming data from the socket
    spawn(name: "ws-consume") { consume_io(websocket, generation) }
  rescue error
    logger.info(exception: error) { "error connecting to device on #{@ip}:#{@port}#{@path}" }
    set_connected_state(false)
    raise error
  end

  def terminate : Nil
    @terminated = true
    @websocket.try(&.close) rescue nil
    @websocket = nil
  end

  def disconnect : Nil
    disconnect(@generation)
  end

  # tears down the connection unless `generation` is stale, i.e. the socket
  # the disconnect was issued against has already been replaced
  protected def disconnect(generation : UInt64) : Nil
    websocket = @websocket
    @connect_lock.synchronize do
      return if @connection_state_changing || generation != @generation
      @websocket = nil
    end
    websocket.try(&.close) rescue nil

    # close yields this fiber; if a reconnect completed while we were
    # suspended the new connection must not be marked offline
    return if generation != @generation

    set_connected_state(false)
    # Spawn the reconnect so disconnect can't grow the stack via the
    # disconnect -> connect -> (ensure) disconnect chain when the device
    # rapidly closes the new socket.
    spawn(name: "ws-reconnect") { connect } unless @terminated
  rescue error
    logger.info(exception: error) { "calling disconnect" }
  end

  protected def set_connected_state(state : Bool)
    @queue.online = state
  rescue error
    logger.info(exception: error) { "setting connected state" }
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

  private def consume_io(websocket, generation)
    websocket.on_ping { |message| websocket.pong(message) }
    websocket.on_binary { |bytes| process bytes }
    websocket.on_message { |string| process string.to_slice }
    websocket.run
  rescue IO::Error
  rescue error
    logger.error(exception: error) { "error consuming IO" }
  ensure
    # ensure the socket reports closed so a concurrent connect's safety check
    # can detect the death even if the disconnect below is dropped — a TCP
    # reset doesn't flag the websocket as closed on its own
    websocket.close rescue nil
    # only call disconnect if we're still processing the same socket
    # if not then connect has already been called or disconnect was
    # called explicitly
    disconnect(generation) if websocket == @websocket
  end
end
