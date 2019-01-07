require "logger"

class EngineDriver::Logger < Logger
  def initialize(module_id : String, @protocol : EngineDriver::Protocol, io = STDOUT)
    super(io)
    @debugging = false
    @progname = module_id
    self.level = Logger::WARN
  end

  property :debugging

  def log(severity, message, progname = nil)
    if @debugging
      message = message.to_s
      @protocol.request @progname, "debug", [severity, message]
    end
    return if severity < level || !@io
    write(severity, Time.now, progname || @progname, message)
  end

  def log(severity, progname = nil)
    return if !@debugging && (severity < level || !@io)
    log(severity, yield, progname)
  end
end
