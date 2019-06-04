require "socket"

class EngineDriver::TransportLogic < EngineDriver::Transport
  def initialize(@queue : EngineDriver::Queue)
  end

  def start_tls(verify_mode, context)
  end

  def terminate
  end

  def connect(connect_timeout : Int32 = 0)
    # This ensures all drivers set connected == true
    @queue.online = true
  end

  def disconnect
  end

  def send(message)
    self
  end

  def send(message, task : EngineDriver::Task, &block : (Bytes, EngineDriver::Task) -> Nil)
    self
  end
end
