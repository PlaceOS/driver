require "simple_retry"
require "socket"

require "../transport"

class PlaceOS::Driver::TransportTCP < PlaceOS::Driver::Transport
  # timeouts in seconds
  def initialize(@queue : PlaceOS::Driver::Queue, @ip : String, @port : Int32, @settings : ::PlaceOS::Driver::Settings, @start_tls = false, @uri = nil, @makebreak = false, &@received : (Bytes, PlaceOS::Driver::Task?) -> Nil)
    # TODO:: makebreak needs a little more consideration around setting connected / disconnected status
    @terminated = false
    @tls_started = false

    # to ensure we don't send anything while negotiating TLS
    # as a TLS upgrade can happen at anytime in the module lifecycle
    @mutex = Mutex.new(:reentrant)
  end

  @uri : String?
  @socket : IO?
  @tls : OpenSSL::SSL::Context::Client?
  property :received

  def connect(connect_timeout : Int32 = 10) : Nil
    return if @terminated
    if socket = @socket
      return unless socket.closed?
    end

    # Clear any buffered data before we re-connect
    @tokenizer.try &.clear

    if @makebreak
      start_socket(connect_timeout)
    else
      SimpleRetry.try_to(
        base_interval: 1.second,
        max_interval: 10.seconds,
        randomise: 500.milliseconds
      ) do
        start_socket(connect_timeout)
      end
    end
  end

  private def start_socket(connect_timeout)
    @mutex.synchronize do
      @socket = socket = TCPSocket.new(@ip, @port, connect_timeout: connect_timeout)
      socket.tcp_nodelay = true

      @tls_started = false
      start_tls if @start_tls

      # We'll manually manage buffering.
      # Classes that support `#write_bytes` may write to the IO multiple times
      # however we don't want packets sent for every call to write
      socket.sync = false
    end

    # Enable queuing
    @queue.online = true

    # Start consuming data from the socket
    spawn(same_thread: true) { consume_io }
  rescue error
    logger.info(exception: error) { "connecting to device" }
    @queue.online = false
    raise error
  end

  # upgrades to an encrpyted socket, can be called from a received function
  def start_tls(verify_mode = OpenSSL::SSL::VerifyMode::NONE, context = @tls) : Nil
    @mutex.synchronize do
      return if @tls_started
      raise "cannot start tls while disconnected" if @socket.nil? || @socket.try(&.closed?)

      # we want negotiation to happen without manual flushing of the IO
      socket = @socket.as(TCPSocket)
      socket.sync = true

      # we can re-use the context
      tls = context || OpenSSL::SSL::Context::Client.new
      tls.verify_mode = verify_mode
      @tls = tls

      # upgrade the socket to TLS
      @socket = OpenSSL::SSL::Socket::Client.new(socket, context: tls, sync_close: true, hostname: @ip)
      @tls_started = true
      socket.sync = false
    end
  end

  def terminate : Nil
    @terminated = true
    @socket.try &.close
  end

  def disconnect : Nil
    @socket.try &.close
  rescue error
    logger.info(exception: error) { "calling disconnect" }
  end

  def send(message) : PlaceOS::Driver::TransportTCP
    connect if @makebreak

    @mutex.synchronize do
      socket = @socket
      return self if socket.nil? || socket.closed?

      if message.responds_to? :to_io
        socket.write_bytes(message)
      elsif message.responds_to? :to_slice
        data = message.to_slice
        socket.write data
      else
        socket << message
      end
      socket.flush
    end
    self
  end

  def send(message, task : PlaceOS::Driver::Task, &block : (Bytes, PlaceOS::Driver::Task) -> Nil) : PlaceOS::Driver::TransportTCP
    task.processing = block
    send(message)
  end

  private def consume_io
    raw_data = Bytes.new(2048)

    while (socket = @socket) && !socket.closed?
      bytes_read = socket.read(raw_data)
      break if bytes_read.zero? # IO was closed

      # Processing occurs on this fiber to provide backpressure and allow
      # for TLS to be started in received function
      process raw_data[0, bytes_read].dup
    end
  rescue IO::Error
  rescue error
    logger.error(exception: error) { "error consuming IO" }
  ensure
    disconnect
    unless @makebreak
      @queue.online = false
      connect
    end
  end
end
