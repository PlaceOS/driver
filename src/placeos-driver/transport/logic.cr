require "socket"

class PlaceOS::Driver::TransportLogic < PlaceOS::Driver::Transport
  def initialize(@queue : PlaceOS::Driver::Queue)
  end

  def start_tls(verify_mode, context) : Nil
  end

  def terminate : Nil
  end

  def connect(connect_timeout : Int32 = 0) : Nil
    # This ensures all drivers set connected == true
    @queue.online = true
  end

  def disconnect : Nil
  end

  def send(message) : PlaceOS::Driver::TransportLogic
    self
  end

  def send(message, task : PlaceOS::Driver::Task, &block : (Bytes, PlaceOS::Driver::Task) -> Nil) : PlaceOS::Driver::TransportLogic
    self
  end
end
