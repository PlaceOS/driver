require "socket"
require "tasker"
require "ssh2"

class EngineDriver::TransportSSH < EngineDriver::Transport
  # timeouts in seconds
  def initialize(@queue : EngineDriver::Queue, @ip : String, @port : Int32, @settings : ::EngineDriver::Settings, &@received : (Bytes, EngineDriver::Task?) -> Nil)
    @terminated = false
    @logger = @queue.logger
  end

  @logger : ::Logger
  @socket : TCPSocket?
  @session : SSH2::Session?
  @shell : SSH2::Channel?
  @keepalive : Tasker::Task?

  property :received
  getter :logger

  class Settings
    JSON.mapping(
      term: String?,
      keepalive: Int32?,

      username: String,
      password: String?,
      passphrase: String?,
      private_key: String?,
      # We should be able to remove this by generating the public from the private
      public_key: String?
    )
  end

  def connect(connect_timeout : Int32 = 10)
    return if @terminated

    if socket = @socket
      return unless socket.closed?
    end

    retry max_interval: 10.seconds do
      supported_methods = nil

      begin
        # Grab the authentication settings
        settings = @settings.get { setting(Settings, :ssh) }

        # Open a connection
        socket = TCPSocket.new(@ip, @port, connect_timeout: connect_timeout)
        socket.tcp_nodelay = true
        socket.sync = true

        # Negotiate the SSH session
        @session = session = SSH2::Session.new(socket)

        # Attempt to authenticate
        supported_methods = session.login_with_noauth(settings.username)
        if supported_methods
          if password = settings.password
            session.login(settings.username, password)
          end

          if prikey = settings.private_key
            pubkey = settings.public_key.not_nil!
            session.login_with_data(settings.username, prikey, pubkey, settings.passphrase.try &.to_slice.to_unsafe)
          end
        end

        raise "all available authentication methods failed" unless session.authenticated?

        # Attempt to open a shell - more often then not shell is the only supported method
        begin
          @shell = shell = session.open_session
          # Set mode https://tools.ietf.org/html/rfc4254#section-8
          shell.request_pty(settings.term || "vt100", [{SSH2::TerminalMode::ECHO, 0u32}])
          shell.shell

          # Start consuming data from the shell
          spawn { consume_io }
        rescue error
          # It may not be fatal if a shell is unable to be negotiated
          # however this would be a rare device so we log the issue.
          if shell = @shell
            shell.close
            @shell = nil
          end
          @logger.warn "unable to negotiage a shell on SSH connection\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"

          # This will track the socket state when there is no shell
          keepalive(settings.keepalive || 30)
        end

        # Enable queuing
        @queue.online = true
      rescue error
        @logger.info {
          supported_methods = ", supported authentication methods: #{supported_methods}" if supported_methods
          "connecting to device#{supported_methods}\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
        }
        raise error
      end
    end
  end

  def keepalive(period)
    @keepalive = Tasker.instance.every(period.seconds) do
      begin
        @session.try &.send_keepalive
      rescue
        no_shell = @shell.nil?
        disconnect
        connect if no_shell
      end
    end
  end

  def terminate
    @terminated = true
    disconnect
  end

  def disconnect
    # Create local copies as reconnect could be called while we are still disconnecting
    shell = @shell
    session = @session
    socket = @socket

    @shell = nil
    @session = nil
    @socket = nil
    @keepalive.try &.cancel
    @keepalive = nil

    begin
      shell.try &.close
      session.try &.disconnect
    rescue
    ensure
      socket.try &.close
    end
  end

  def send(message) : Int32
    socket = @shell
    return 0 if socket.nil? || socket.closed?
    data = message.to_slice
    socket.write data
    data.bytesize
  end

  def send(message, task : EngineDriver::Task, &block : Bytes -> Nil) : Int32
    socket = @shell
    return 0 if socket.nil? || socket.closed?
    task.processing = block
    data = message.to_slice
    socket.write data
    data.bytesize
  end

  private def consume_io
    raw_data = Bytes.new(2048)
    if socket = @shell
      while !socket.closed?
        bytes_read = socket.read(raw_data)
        break if bytes_read == 0 # IO was closed

        data = raw_data[0, bytes_read]
        spawn { process(data) }
      end
    end
  rescue IO::Error | Errno | SSH2::SessionError
  rescue error
    @logger.error "error consuming IO\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
  ensure
    disconnect
    connect
  end

  def start_tls(verify_mode = OpenSSL::SSL::VerifyMode::NONE, context = nil)
    true
  end
end
