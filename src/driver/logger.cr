require "action-controller/logger"
require "log_helper"

class PlaceOS::Driver
  class_property logger_io : IO = STDOUT
  LOG_FORMATTER = ActionController.default_formatter

  # Allow signals to change the log level at run-time
  log_level_change = Proc(Signal, Nil).new do |signal|
    level = signal.usr1? ? ::Log::Severity::Debug : ::Log::Severity::Info
    Log.info { "> Log level changed to #{level}" }

    backend = ::Log::IOBackend.new(PlaceOS::Driver.logger_io)
    backend.formatter = PlaceOS::Driver::LOG_FORMATTER
    Log.builder.bind "*", level, backend
    signal.ignore
  end

  # Turn on DEBUG level logging `kill -s USR1 %PID`
  # Default production log levels (INFO and above) `kill -s USR2 %PID`
  Signal::USR1.trap &log_level_change
  Signal::USR2.trap &log_level_change

  # Custom backend that writes to a `PlaceOS::Driver::Protocol`
  class ProtocolBackend < ::Log::Backend
    getter protocol : Protocol
    getter formatter = PlaceOS::Driver::LOG_FORMATTER

    property debugging : Bool

    def initialize(@debugging : Bool = false, @protocol = Protocol.instance)
    end

    def write(entry : ::Log::Entry)
      if debugging
        message = format(entry)
        protocol.request entry.source, "debug", [entry.severity, message]
      end
    end

    protected def format(entry : ::Log::Entry) : String
      output = IO::Memory.new
      formatter.call(entry, output)
      output.to_s
    end
  end

  # Custom Log that broadcasts to a `Log::IOBackend` and `PlaceOS::Driver::ProtocolBackend`
  class Log < ::Log
    getter broadcast_backend : ::Log::BroadcastBackend
    getter io_backend : ::Log::IOBackend
    getter protocol_backend : ProtocolBackend

    delegate :debugging=, :debugging, to: protocol_backend

    def initialize(
      module_id : String,
      logger_io : IO = ::PlaceOS::Driver.logger_io,
      @protocol : Protocol = Protocol.instance,
      severity : ::Log::Severity = ::Log::Severity::Info
    )
      # Create a Driver protocol log backend
      @protocol_backend = ProtocolBackend.new(debugging: false, protocol: @protocol)

      # Create a IO based log backend
      @io_backend = ::Log::IOBackend.new(logger_io)
      io_backend.formatter = PlaceOS::Driver::LOG_FORMATTER

      # Combine backends
      @broadcast_backend = ::Log::BroadcastBackend.new
      broadcast_backend.append(io_backend, severity)
      broadcast_backend.append(protocol_backend, severity)
      super(module_id, broadcast_backend, severity)
    end

    def level=(severity : ::Log::Severity)
      protocol_backend.level = severity
      io_backend.level = severity
      broadcast_backend.level = severity
      super(severity)
    end
  end
end
