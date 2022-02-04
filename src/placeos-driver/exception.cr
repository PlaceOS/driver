class PlaceOS::Driver::RemoteException < Exception
  getter? backtrace
  getter code : Int32

  def initialize(message : String?, class_name : String?, @backtrace = [] of String, @code : Int32 = 500)
    @message = "#{message} (#{class_name})"
  end

  def initialize(@message : String, @cause : Exception, @backtrace : Array(String), @code : Int32 = 500)
  end
end
