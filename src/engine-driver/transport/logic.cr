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

  def send(message) : Int32
    0
  end

  def send(message, task : EngineDriver::Task, &block : Bytes -> Nil) : Int32
    0
  end
end
