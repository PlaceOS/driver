abstract class EngineDriver::Transport
  abstract def send(message) : Int32
  abstract def send(message, task : EngineDriver::Task, &block : Bytes -> Nil) : Int32
  abstract def terminate : Nil
  abstract def disconnect : Nil
  abstract def start_tls(verify_mode : OpenSSL::SSL::VerifyMode, context : OpenSSL::SSL::Context) : Nil
  abstract def connect(connect_timeout : Int32)

  protected def process(data) : Nil
    # Check if the task provided a response processing block
    if task = @queue.current
      if processing = task.processing
        processing.call(data)
        return
      end
    end

    # See spec for how this callback is expected to be used
    @received.call(data, @queue.current)
  rescue error
    @logger.error "error processing received data\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
  end
end
