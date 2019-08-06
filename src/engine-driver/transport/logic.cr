require "socket"

class EngineDriver::TransportLogic < EngineDriver::Transport
  def initialize(@queue : EngineDriver::Queue)
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

  def send(message) : EngineDriver::TransportLogic
    self
  end

  def send(message, task : EngineDriver::Task, &block : (Bytes, EngineDriver::Task) -> Nil) : EngineDriver::TransportLogic
    self
  end
end
