require "./constants"
require "./logger_io"

class PlaceOS::Driver
  # Set up logging
  log_io = PlaceOS::Startup.suppress_logs ? IO::Memory.new : STDOUT
  PlaceOS::Driver.logger_io = log_io

  # Process-wide root-logger backend, created once and reused. Reusing it means
  # toggling the log level (USR1) doesn't strand the previous backend's async
  # dispatcher fiber.
  @@global_log_backend : ::Log::IOBackend? = nil

  def self.global_log_backend : ::Log::IOBackend
    existing = @@global_log_backend
    return existing if existing

    backend = ::Log::IOBackend.new(PlaceOS::Driver.logger_io)
    backend.formatter = LOG_FORMATTER
    @@global_log_backend = backend
    backend
  end

  ::Log.setup("*", ::Log::Severity::Error, global_log_backend)

  # :nodoc:
  class_getter trace : Bool = false

  # Change the log level at run-time.
  # Toggle TRACE level logging using `kill -s USR1 %PID`
  def self.register_log_level_signal
    Signal::USR1.trap do |signal|
      @@trace = !@@trace
      level = @@trace ? ::Log::Severity::Trace : ::Log::Severity::Error
      Log.info { "> Log level changed to #{level}" }

      # Reuse the existing backend and re-run `Log.setup` (which resets the
      # bindings) at the new level. Previously each toggle created a fresh
      # `Log::IOBackend` and `builder.bind`ed it: the old backends were never
      # closed (leaking their async dispatcher fibers) and stayed bound
      # (duplicating every log line).
      ::Log.setup("*", level, global_log_backend)
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
    getter io_severity : ::Log::Severity

    def debugging=(value : Bool)
      @debugging = value

      # Don't worry it's not really an append, it's updating a hash with the
      # backend as the key, so this is a clean update
      @broadcast_backend.append(@protocol_backend, value ? ::Log::Severity::Debug : ::Log::Severity::None)
      self.level = value ? ::Log::Severity::Debug : @io_severity
    end

    def override_io_severity(severity : ::Log::Severity)
      @io_severity = severity
      # Don't worry it's not really an append, it's updating a hash
      @broadcast_backend.append(@io_backend, severity)
      self.level = @debugging ? ::Log::Severity::Debug : severity
    end

    def initialize(
      module_id : String,
      logger_io : IO = ::PlaceOS::Driver.logger_io,
      @protocol : Protocol = Protocol.instance,
      severity : ::Log::Severity = ::Log::Severity::Error,
    )
      @debugging = false
      @io_severity = severity

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

    # Shuts down the backends' async dispatchers. Each `Log::IOBackend` /
    # `ProtocolBackend` owns a `Log::AsyncDispatcher` whose `write_logs` fiber
    # blocks forever on its channel until closed. Without this, every module
    # stop/restart strands two of those fibers (they keep the dispatcher
    # referenced, so GC can't finalize them) - a per-module fiber leak.
    # Closing the dispatchers does not affect the shared output IO.
    def close : Nil
      @broadcast_backend.close
    end
  end
end
