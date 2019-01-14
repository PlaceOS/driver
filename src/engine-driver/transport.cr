abstract class EngineDriver::Transport
  abstract def send(message) : Int32
  abstract def send(message, task : EngineDriver::Task, &block : Bytes -> Nil) : Int32
  abstract def terminate : Nil
  abstract def disconnect : Nil
end
