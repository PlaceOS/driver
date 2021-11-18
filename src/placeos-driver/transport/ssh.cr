require "simple_retry"
require "socket"
require "ssh2"
require "tasker"

require "../transport"

class PlaceOS::Driver
  protected def exec(message)
    transport.exec(message)
  end

  class TransportSSH < Transport
    # timeouts in seconds
    def initialize(@queue : PlaceOS::Driver::Queue, @ip : String, @port : Int32, @settings : ::PlaceOS::Driver::Settings, @uri = nil, &@received : (Bytes, PlaceOS::Driver::Task?) -> Nil)
      @terminated = false
    end

    @uri : String?
    @socket : TCPSocket?
    @session : SSH2::Session?
    @shell : SSH2::Channel?
    @keepalive : Tasker::Task?
    @ssh_settings : Settings?
    @messages : Channel(Bytes)?
    @connecting : Bool = false

    property :received

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

    # ameba:disable Metrics/CyclomaticComplexity
    def connect(connect_timeout : Int32 = 10) : Nil
      return if @terminated || @connecting || @messages
      @connecting = true

      # Clear any buffered data before we re-connect
      tokenizer = @tokenizer
      tokenizer.clear if tokenizer

      SimpleRetry.try_to(
        base_interval: 1.second,
        max_interval: 10.seconds,
        randomise: 500.milliseconds
      ) do
        supported_methods = nil

        begin
          messages = @messages
          @messages = Channel(Bytes).new
          messages.try &.close

          # Grab the authentication settings (using not_nil for schema generation)
          @ssh_settings = settings = @settings.get { setting?(Settings, :ssh) }.not_nil!

          # Open a connection
          @socket = socket = TCPSocket.new(@ip, @port, connect_timeout: connect_timeout)
          socket.tcp_nodelay = true
          socket.sync = true

          # Negotiate the SSH session
          session = SSH2::Session.new(socket)

          # Attempt to authenticate
          supported_methods = session.login_with_noauth(settings.username)
          if supported_methods
            if supported_methods.is_a?(Array(String))
              logger.debug { "supported auhentication methods: #{supported_methods}" }

              supported_methods.each do |auth_method|
                case auth_method
                when "publickey"
                  if prikey = settings.private_key
                    begin
                      pubkey = settings.public_key.not_nil!
                      session.login_with_data(settings.username, prikey, pubkey, settings.passphrase)
                    rescue SSH2::SessionError
                      logger.warn { "publickey auth failed, incorrect key" }
                    end
                  else
                    logger.debug { "ignoring publickey authentication as no key provided" }
                  end
                when "password"
                  if password = settings.password
                    begin
                      session.login(settings.username, password)
                    rescue SSH2::SessionError
                      logger.warn { "password auth failed, incorrect password" }
                    end
                  else
                    logger.debug { "ignoring password authentication as no password provided" }
                  end
                when "keyboard-interactive"
                  if settings.password
                    begin
                      session.interactive_login(settings.username) { @ssh_settings.not_nil!.password.not_nil! }
                    rescue SSH2::SessionError
                      logger.warn { "password auth failed, incorrect password" }
                    end
                  else
                    logger.debug { "ignoring keyboard-interactive authentication as no password provided" }
                  end
                else
                  logger.debug { "ignoring unsupported authentication method: #{auth_method}" }
                end

                break if session.authenticated?
              end
            else
              if password = settings.password
                begin
                  session.login(settings.username, password)
                rescue error : SSH2::SessionError
                  begin
                    session.interactive_login(settings.username) { @ssh_settings.not_nil!.password.not_nil! }
                  rescue SSH2::SessionError
                    logger.warn { "password auth failed, either not supported or incorrect password" }
                  end
                end
              end

              if !session.authenticated? && (prikey = settings.private_key)
                begin
                  pubkey = settings.public_key.not_nil!
                  session.login_with_data(settings.username, prikey, pubkey, settings.passphrase)
                rescue SSH2::SessionError
                  logger.warn { "publickey auth failed, either not supported or incorrect key" }
                end
              end
            end
          end

          raise "all available authentication methods failed" unless session.authenticated?

          # Attempt to open a shell - more often then not shell is the only supported method
          begin
            Promise(Nil).defer(same_thread: true, timeout: 5.seconds) {
              @shell = shell = session.open_session
              # Set mode https://tools.ietf.org/html/rfc4254#section-8
              shell.request_pty(settings.term || "vt100", [{SSH2::TerminalMode::ECHO, 0u32}])
              shell.shell
            }.get
          rescue error
            # It may not be fatal if a shell is unable to be negotiated
            # however this would be a rare device so we log the issue.
            if shell = @shell
              shell.close
              @shell = nil
            end
            logger.warn(exception: error) { "unable to negotiage a shell on SSH connection" }
          end
          @session = session

          # This will track the socket state when there is no shell
          keepalive(settings.keepalive || 30)

          # Start consuming data from the shell
          spawn(same_thread: true) { consume_messages } if @shell

          # Enable queuing
          @queue.online = true
        rescue error
          logger.info(exception: error) {
            supported_methods = ", supported authentication methods: #{supported_methods}" if supported_methods
            "connecting to device#{supported_methods}"
          }
          @queue.online = false
          begin
            @socket.try &.close
            @socket = nil
            @shell = nil
            @session = nil
          rescue
          end
          raise error
        end
      end
      @connecting = false
    end

    def keepalive(period)
      @keepalive = Tasker.every(period.seconds) do
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
      return unless @messages

      # Create local copies as reconnect could be called while we are still disconnecting
      messages = @messages
      socket = @socket
      shell = @shell
      session = @session
      @messages = nil
      @socket = nil
      @shell = nil
      @session = nil
      @keepalive.try &.cancel
      @keepalive = nil

      begin
        Promise(Nil).defer(same_thread: true, timeout: 3.seconds) {
          shell.try &.close
          session.try &.disconnect
        }.get
      rescue
      end

      begin
        socket.try &.close
      rescue
      ensure
        messages.try &.close
      end
    rescue error
      logger.info(exception: error) { "calling disconnect" }
    end

    def send(message) : TransportSSH
      socket = @shell
      if socket.nil? || socket.closed?
        if @session
          logger.warn { "disconnecting as no shell negotiated for sending message" }
          disconnect
        end
        return self
      end

      case message
      when .responds_to? :to_io    then socket.write_bytes(message)
      when .responds_to? :to_slice then socket.write message.to_slice
      else
        socket << message
      end
      self
    end

    def send(message, task : PlaceOS::Driver::Task, &block : (Bytes, PlaceOS::Driver::Task) -> Nil) : TransportSSH
      task.processing = block
      send(message)
    end

    private def consume_messages
      if messages = @messages
        spawn(same_thread: true) { consume_io }

        while raw_data = messages.receive?
          process raw_data
        end
      end
    rescue error
      logger.error(exception: error) { "error consuming IO" }
    ensure
      disconnect
      @queue.online = false
      connect
    end

    private def consume_io
      messages = @messages

      begin
        raw_data = Bytes.new(2048)
        if (socket = @shell) && messages
          while !socket.closed? && !messages.closed?
            bytes_read = socket.read(raw_data)
            break if bytes_read == 0 || messages != @messages # IO was closed

            messages.send raw_data[0, bytes_read].dup
          end
        end
      rescue IO::Error | SSH2::SessionError | Channel::ClosedError
      rescue error
        logger.error(exception: error) { "error consuming IO" }
      ensure
        messages.try &.close
      end
    end

    def start_tls(verify_mode = OpenSSL::SSL::VerifyMode::NONE, context = nil) : Nil
    end
  end
end
