class EngineDriver::RemoteException < Exception
  def initialize(message, class_name, @backtrace = [] of String)
    @message = "#{class_name.to_s}: #{message.to_s}"
  end

  def backtrace?
    @backtrace
  end
end
