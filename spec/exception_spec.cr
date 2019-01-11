require "./helper"

describe EngineDriver::RemoteException do
  it "should reconstruct an existing exception" do
    queue = Helper.queue
    queue.online = true

    t = queue.add {
      raise "error"
    }

    result = t.get
    queue.terminate

    error = EngineDriver::RemoteException.new(result.payload, result.error_class, result.backtrace)
    error.message.should eq("Exception: error")
    error.backtrace.should eq(result.backtrace)
    (error.backtrace.size > 0).should eq(true)
  end
end
