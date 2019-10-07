require "socket"
require "openssl"

class EngineDriver::TransportUDP < EngineDriver::Transport
  MULTICASTRANGEV4 = IPAddress.new("224.0.0.0/4")
  MULTICASTRANGEV6 = IPAddress.new("ff00::/8")

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

  def connect(connect_timeout : Int32 = 10) : Nil
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

        # Join multicast group if the in the correct range
        begin
          ipaddr = IPAddress.new(@ip)
          if ipaddr.is_a?(IPAddress::IPv4) ? MULTICASTRANGEV4.includes?(ipaddr) : MULTICASTRANGEV6.includes?(ipaddr)
            socket.join_group(Socket::IPAddress.new(@ip, @port))

            if hops = @settings.get { setting?(UInt8, :multicast_hops) }
              socket.multicast_hops = hops
            end
          end
        rescue ArgumentError
          # @ip is a hostname
        end

        # Start consuming data from the socket
        spawn(same_thread: true) { consume_io }
      rescue error
        @logger.info { "connecting to device\n#{error.inspect_with_backtrace}" }
        raise error
      end
    end
  end

  def start_tls(verify_mode = OpenSSL::SSL::VerifyMode::NONE, context = @tls) : Nil
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

  def terminate : Nil
    @terminated = true
    @socket.try &.close
  end

  def disconnect : Nil
    @socket.try &.close
  end

  def send(message) : EngineDriver::TransportUDP
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

  def send(message, task : EngineDriver::Task, &block : (Bytes, EngineDriver::Task) -> Nil) : EngineDriver::TransportUDP
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
    connect
  end
end
