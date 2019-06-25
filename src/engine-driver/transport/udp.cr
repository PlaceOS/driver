require "socket"
require "openssl"

# TODO:: remove once crystal lang 0.27.3+ is released
lib LibSSL
  {% if compare_versions(OPENSSL_VERSION, "1.0.2") >= 0 %}
  	fun dtls_method = DTLS_method : SSLMethod
  {% end %}
end

class EngineDriver::TransportUDP < EngineDriver::Transport
  # timeouts in seconds
  def initialize(@queue : EngineDriver::Queue, @ip : String, @port : Int32, @settings : ::EngineDriver::Settings, @start_tls = false, @uri = nil, &@received : (Bytes, EngineDriver::Task?) -> Nil)
    @terminated = false
    @tls_started = false
    @logger = @queue.logger
  end

  @uri : String?
  @logger : ::Logger
  @socket : IO?
  @tls : OpenSSL::SSL::Context::Client?
  @settings : ::EngineDriver::Settings

  property :received
  getter :logger

  def connect(connect_timeout : Int32 = 10)
    return if @terminated
    if socket = @socket
      return unless socket.closed?
    end

    retry max_interval: 10.seconds do
      begin
        @socket = socket = UDPSocket.new
        socket.connect(@ip, @port)
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
        spawn { consume_io }
      rescue error
        @logger.info { "connecting to device\n#{error.message}\n#{error.backtrace?.try &.join("\n")}" }
        raise error
      end
    end
  end

  def start_tls(verify_mode = OpenSSL::SSL::VerifyMode::NONE, context = @tls)
    {% if compare_versions(LibSSL::OPENSSL_VERSION, "1.0.2") >= 0 %}
      return if @tls_started
      socket = @socket
      raise "cannot start tls while disconnected" if socket.nil? || socket.closed?

      # we can re-use the context
      tls = context || OpenSSL::SSL::Context::Client.new(LibSSL.dtls_method)
      tls.verify_mode = verify_mode
      @tls = tls

      # upgrade the socket to TLS
      @socket = OpenSSL::SSL::Socket::Client.new(socket, context: tls, sync_close: true, hostname: @ip)
      @tls_started = true
    {% else %}
      raise "DTLS not supported in the linked version of OpenSSL #{LibSSL::OPENSSL_VERSION} or LibreSSL #{LibSSL::LIBRESSL_VERSION}"
    {% end %}
  end

  def terminate
    @terminated = true
    @socket.try &.close
  end

  def disconnect
    @socket.try &.close
  end

  def send(message)
    socket = @socket
    return 0 if socket.nil? || socket.closed?
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

  def send(message, task : EngineDriver::Task, &block : (Bytes, EngineDriver::Task) -> Nil)
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
        spawn { process(data) }
      end
    end
  rescue IO::Error | Errno
  rescue error
    @logger.error "error consuming IO\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
  ensure
    connect
  end
end
