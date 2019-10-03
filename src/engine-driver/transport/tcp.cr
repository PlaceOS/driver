require "socket"

class EngineDriver::TransportTCP < EngineDriver::Transport
  # timeouts in seconds
  def initialize(@queue : EngineDriver::Queue, @ip : String, @port : Int32, @settings : ::EngineDriver::Settings, @start_tls = false, @uri = nil, @makebreak = false, &@received : (Bytes, EngineDriver::Task?) -> Nil)
    # TODO:: makebreak needs a little more consideration around setting connected / disconnected status
    @terminated = false
    @tls_started = false
    @logger = @queue.logger
  end

  @uri : String?
  @logger : ::Logger
  @socket : IO?
  @tls : OpenSSL::SSL::Context::Client?
  property :received
  getter :logger

  def connect(connect_timeout : Int32 = 10) : Nil
    return if @terminated
    if socket = @socket
      return unless socket.closed?
    end

    # Clear any buffered data before we re-connect
    tokenizer = @tokenizer
    tokenizer.clear if tokenizer

    if @makebreak
      start_socket(connect_timeout)
    else
      retry max_interval: 10.seconds do
        start_socket(connect_timeout)
      end
    end
  end

  private def start_socket(connect_timeout)
    @socket = socket = TCPSocket.new(@ip, @port, connect_timeout: connect_timeout)
    socket.tcp_nodelay = true
    socket.sync = true

    @tls_started = false
    start_tls if @start_tls

    # Enable queuing
    @queue.online = true

    # We'll manually manage buffering.
    # Classes that support `#write_bytes` may write to the IO multiple times
    # however we don't want packets sent for every call to write
    socket.sync = false

    # Start consuming data from the socket
    spawn(same_thread: true) { consume_io }
  rescue error
    @logger.info { "connecting to device\n#{error.inspect_with_backtrace}" }
    raise error
  end

  def start_tls(verify_mode = OpenSSL::SSL::VerifyMode::NONE, context = @tls) : Nil
    return if @tls_started
    socket = @socket
    raise "cannot start tls while disconnected" if socket.nil? || socket.closed?

    # we can re-use the context
    tls = context || OpenSSL::SSL::Context::Client.new
    tls.verify_mode = verify_mode
    @tls = tls

    # upgrade the socket to TLS
    @socket = OpenSSL::SSL::Socket::Client.new(socket, context: tls, sync_close: true, hostname: @ip)
    @tls_started = true
  end

  def terminate : Nil
    @terminated = true
    @socket.try &.close
  end

  def disconnect : Nil
    @socket.try &.close
  end

  def send(message) : EngineDriver::TransportTCP
    connect if @makebreak

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
    self
  end

  def send(message, task : EngineDriver::Task, &block : (Bytes, EngineDriver::Task) -> Nil) : EngineDriver::TransportTCP
    task.processing = block
    send(message)
  end

  private def consume_io
    raw_data = Bytes.new(2048)
    if socket = @socket
      while !socket.closed?
        bytes_read = socket.read(raw_data)
        break if bytes_read == 0 # IO was closed

        data = raw_data[0, bytes_read]
        spawn(same_thread: true) { process data }
      end
    end
  rescue IO::Error | Errno
  rescue error
    @logger.error "error consuming IO\n#{error.inspect_with_backtrace}"
  ensure
    connect unless @makebreak
  end
end
