require "./constants"
require "./logger_io"

class PlaceOS::Driver
  # Set up logging
  log_io = PlaceOS::Startup.suppress_logs ? IO::Memory.new : STDOUT
  PlaceOS::Driver.logger_io = log_io
  backend = ::Log::IOBackend.new(log_io)
  backend.formatter = LOG_FORMATTER
  ::Log.setup("*", ::Log::Severity::Error, backend)

  # :nodoc:
  class_getter trace : Bool = false

  # Change the log level at run-time.
  # Toggle TRACE level logging using `kill -s USR1 %PID`
  def self.register_log_level_signal
    Signal::USR1.trap do |signal|
      @@trace = !@@trace
      level = @@trace ? ::Log::Severity::Trace : ::Log::Severity::Error
      Log.info { "> Log level changed to #{level}" }

      backend = ::Log::IOBackend.new(PlaceOS::Driver.logger_io)
      backend.formatter = PlaceOS::Driver::LOG_FORMATTER
      Log.builder.bind "*", level, backend
      signal.ignore
      register_log_level_signal
    end
  end

  PlaceOS::Driver.register_log_level_signal

  # :nodoc:
  # Custom backend that writes to a `PlaceOS::Driver::Protocol`
  class ProtocolBackend < ::Log::Backend
    getter protocol : Protocol

    def initialize(@protocol = Protocol.instance)
      @dispatcher = ::Log::AsyncDispatcher.new(16)
    end

    def write(entry : ::Log::Entry)
      message = (exception = entry.exception) ? "#{entry.message}\n#{exception.inspect_with_backtrace}" : entry.message
      protocol.request entry.source, Protocol::Request::Command::Debug, [entry.severity.to_i, message]
    end
  end

  # :nodoc:
  # Custom Log that broadcasts to a `Log::IOBackend` and `PlaceOS::Driver::ProtocolBackend`
  class Log < ::Log
    getter broadcast_backend : ::Log::BroadcastBackend
    getter io_backend : ::Log::IOBackend
    getter protocol_backend : ProtocolBackend
    getter debugging : Bool

    def debugging=(value : Bool)
      @debugging = value

      # Don't worry it's not really an append, it's updating a hash with the
      # backend as the key, so this is a clean update
      @broadcast_backend.append(@protocol_backend, value ? ::Log::Severity::Debug : ::Log::Severity::None)
      self.level = value ? ::Log::Severity::Debug : ::Log::Severity::Error
    end

    def initialize(
      module_id : String,
      logger_io : IO = ::PlaceOS::Driver.logger_io,
      @protocol : Protocol = Protocol.instance,
      severity : ::Log::Severity = ::Log::Severity::Error,
    )
      @debugging = false

      # Create a Driver protocol log backend
      @protocol_backend = ProtocolBackend.new(protocol: @protocol)

      # Create a IO based log backend
      @io_backend = ::Log::IOBackend.new(logger_io)
      @io_backend.formatter = PlaceOS::Driver::LOG_FORMATTER

      # Combine backends
      @broadcast_backend = ::Log::BroadcastBackend.new
      broadcast_backend.append(io_backend, severity)
      broadcast_backend.append(protocol_backend, ::Log::Severity::None)
      super(module_id, broadcast_backend, severity)

      # NOTE:: if broadcast level is set then it overrides the backend severity levels
      @broadcast_backend.level = nil
    end

    def level=(severity : ::Log::Severity)
      super(severity)

      # NOTE:: if broadcast level is set then it overrides the backend severity levels
      @broadcast_backend.level = nil
    end
  end
end
