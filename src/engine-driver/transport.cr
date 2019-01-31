abstract class EngineDriver::Transport
  abstract def send(message) : Int32
  abstract def send(message, task : EngineDriver::Task, &block : Bytes -> Nil) : Int32
  abstract def terminate : Nil
  abstract def disconnect : Nil
  abstract def start_tls(verify_mode : OpenSSL::SSL::VerifyMode, context : OpenSSL::SSL::Context) : Nil
  abstract def connect(connect_timeout : Int32)
end
