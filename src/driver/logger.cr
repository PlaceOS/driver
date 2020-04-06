require "logger"

class PlaceOS::Driver
  LOGGER = ::Logger.new(STDOUT, level: ::Logger::INFO)
  LOGGER.formatter = Logger::Formatter.new do |severity, datetime, progname, message, io|
    label = severity.unknown? ? "ANY" : severity.to_s
    io << String.build do |str|
      str << "level=" << label << " time="
      datetime.to_rfc3339(str)
      str << " progname=" << (progname || PROGRAM_NAME) << " message=" << message
    end
  end

  # Allow signals to change the log level at run-time
  logging = Proc(Signal, Nil).new do |signal|
    level = signal.usr1? ? ::Logger::DEBUG : ::Logger::INFO
    LOGGER.info " > Log level changed to #{level}"
    LOGGER.level = level
    signal.ignore
  end

  # Turn on DEBUG level logging `kill -s USR1 %PID`
  # Default production log levels (INFO and above) `kill -s USR2 %PID`
  Signal::USR1.trap &logging
  Signal::USR2.trap &logging

  class Logger < Logger
    def initialize(module_id : String, logger_io = STDOUT, @protocol = Protocol.instance)
      super(logger_io)
      @debugging = false
      @progname = module_id
      self.level = Logger::WARN
      self.formatter = Logger::Formatter.new do |severity, datetime, progname, message, io|
        # method=DELETE path=/build/drivers%2Faca%2Fspec_helper.cr/ status=200 duration=32.65ms request_id=8a14cef3-15ea-4d2d-ad55-cff5799d4add

        label = severity.unknown? ? "ANY" : severity.to_s
        io << String.build do |str|
          str << "level=" << label << " time="
          datetime.to_rfc3339(str)
          str << " progname=" << progname << " message=" << message
        end
      end
    end

    @protocol : Protocol
    property :debugging

    def log(severity, message, progname = nil)
      if @debugging
        message = message.to_s
        @protocol.request @progname, "debug", [severity, message]
      end
      return if severity < level || !@io
      write(severity, Time.local, progname || @progname, message)
    end

    def log(severity, progname = nil)
      return if !@debugging && (severity < level || !@io)
      log(severity, yield, progname)
    end
  end
end
