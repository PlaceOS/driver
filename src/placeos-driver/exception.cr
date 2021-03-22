class PlaceOS::Driver::RemoteException < Exception
  getter? backtrace

  def initialize(message, class_name, @backtrace = [] of String)
    @message = "#{message} (#{class_name})"
  end
end
