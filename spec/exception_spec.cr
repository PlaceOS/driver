require "./helper"

describe ACAEngine::Driver::RemoteException do
  it "should reconstruct an existing exception" do
    queue = Helper.queue
    queue.online = true

    t = queue.add {
      raise "error"
    }

    result = t.get
    queue.terminate

    error = ACAEngine::Driver::RemoteException.new(result.payload, result.error_class, result.backtrace)
    error.message.should eq("error (Exception)")
    error.backtrace.should eq(result.backtrace)
    (error.backtrace.size > 0).should eq(true)
  end
end
