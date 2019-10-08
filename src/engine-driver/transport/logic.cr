require "socket"

class ACAEngine::Driver::TransportLogic < ACAEngine::Driver::Transport
  def initialize(@queue : ACAEngine::Driver::Queue)
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

  def send(message) : ACAEngine::Driver::TransportLogic
    self
  end

  def send(message, task : ACAEngine::Driver::Task, &block : (Bytes, ACAEngine::Driver::Task) -> Nil) : ACAEngine::Driver::TransportLogic
    self
  end
end
