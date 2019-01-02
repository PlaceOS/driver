class EngineDriver::RemoteException < Exception
  def initialize(@message : String, @backtrace = [] of String)
  end

  def backtrace?
    @backtrace
  end
end
