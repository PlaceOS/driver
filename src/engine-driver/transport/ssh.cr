require "socket"
require "tasker"
require "ssh2"

class EngineDriver
  protected def exec(message)
    transport.exec(message)
  end

  class TransportSSH < Transport
    # timeouts in seconds
    def initialize(@queue : EngineDriver::Queue, @ip : String, @port : Int32, @settings : ::EngineDriver::Settings, @uri = nil, &@received : (Bytes, EngineDriver::Task?) -> Nil)
      @terminated = false
      @logger = @queue.logger
    end

    @uri : String?
    @logger : ::Logger
    @socket : TCPSocket?
    @session : SSH2::Session?
    @shell : SSH2::Channel?
    @keepalive : Tasker::Task?

    property :received
    getter :logger

    class Settings
      include JSON::Serializable

      property term : String?
      property keepalive : Int32?

      property username : String
      property password : String?
      property passphrase : String?
      property private_key : String?

      # We should be able to remove this by generating the public from the private
      property public_key : String?
    end

    def exec(message) : SSH2::Channel
      session = @session
      raise "SSH session not started" unless session
      channel = session.open_session
      channel.command(message.to_s)
      channel
    end

    def connect(connect_timeout : Int32 = 10) : Nil
      return if @terminated

      if socket = @socket
        return unless socket.closed?
      end

      # Clear any buffered data before we re-connect
      tokenizer = @tokenizer
      tokenizer.clear if tokenizer

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
            @logger.warn "unable to negotiage a shell on SSH connection\n#{error.inspect_with_backtrace}"
          end

          # This will track the socket state when there is no shell
          keepalive(settings.keepalive || 30)

          # Enable queuing
          @queue.online = true
        rescue error
          @logger.info {
            supported_methods = ", supported authentication methods: #{supported_methods}" if supported_methods
            "connecting to device#{supported_methods}\n#{error.inspect_with_backtrace}"
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

    def terminate : Nil
      @terminated = true
      disconnect
    end

    def disconnect : Nil
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

    def send(message) : TransportSSH
      socket = @shell
      return self if socket.nil? || socket.closed?
      if message.responds_to? :to_io
        socket.write_bytes(message)
      elsif message.responds_to? :to_slice
        data = message.to_slice
        socket.write data
      else
        socket << message
      end
      self
    end

    def send(message, task : EngineDriver::Task, &block : (Bytes, EngineDriver::Task) -> Nil) : TransportSSH
      task.processing = block
      send(message)
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
      @logger.error "error consuming IO\n#{error.inspect_with_backtrace}"
    ensure
      disconnect
      connect
    end

    def start_tls(verify_mode = OpenSSL::SSL::VerifyMode::NONE, context = nil) : Nil
    end
  end
end
