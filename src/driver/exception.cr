class PlaceOS::Driver::RemoteException < Exception
  def initialize(message, class_name, @backtrace = [] of String)
    @message = "#{message} (#{class_name})"
  end

  def backtrace?
    @backtrace
  end
end
