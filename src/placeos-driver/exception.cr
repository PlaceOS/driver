class PlaceOS::Driver::RemoteException < Exception
  getter? backtrace

  def initialize(message : String?, class_name : String?, @backtrace = [] of String)
    @message = "#{message} (#{class_name})"
  end

  def initialize(@message : String, @cause : Exception, @backtrace : Array(String))
  end
end
