require "./helper"
require "../src/placeos-driver/protocol/management"

# Regression coverage for a wedge that survived until the process restarted.
#
# `Management#start` blocks on a promise held in `@starting`, and only a `start`
# response settles it. But start frames carry no sequence number, and the driver's
# failure path (`Request#set_error`) rewrites `cmd` to `:result` — so a driver that
# fails to start replies `cmd: :result, seq: nil`. The result branch did
# `request.seq.not_nil!`, which raised inside the `process_request` fiber, killed
# it, and left the start promise unsettled forever.
class PlaceOS::Driver::Protocol
  # Test hooks: drive `process` directly with a crafted frame so these specs
  # exercise the protocol handling without launching a driver subprocess.
  class Management
    def test_pending_start(module_id : String) : Promise::DeferredPromise(Nil)
      request_lock.synchronize { @starting[module_id] = Promise.new(Nil) }
    end

    # Registers a request the same way `execute` does.
    def test_pending_request : {UInt64, Promise::DeferredPromise(Tuple(String, Int32))}
      promise = Promise.new(Tuple(String, Int32))
      sequence = request_lock.synchronize do
        seq = @sequence
        @sequence = seq &+ 1
        @requests[seq] = promise
        seq
      end
      {sequence, promise}
    end

    def test_process(request : Request) : Nil
      process(request)
    end
  end
end

describe PlaceOS::Driver::Protocol::Management do
  describe "result frames without a sequence number" do
    it "fails a pending start instead of leaving the caller blocked" do
      manager = PlaceOS::Driver::Protocol::Management.new("./test_build")
      promise = manager.test_pending_start("mod-start-failure")

      # Exactly what a driver emits when it cannot start.
      request = PlaceOS::Driver::Protocol::Request.new("mod-start-failure", :start)
      request.set_error(Exception.new("driver was not compiled with HTTP transport support, declare `uri_base`"))

      # The shape that used to be unhandled.
      request.seq.should be_nil
      request.cmd.result?.should be_true

      manager.test_process(request)

      error = expect_raises(PlaceOS::Driver::RemoteException) do
        promise.get
      end
      error.message.to_s.should contain "uri_base"
    end

    it "does not raise when there is no pending start to settle" do
      manager = PlaceOS::Driver::Protocol::Management.new("./test_build")

      # Previously a `NilAssertionError`, which killed the fiber that was meant
      # to deliver every subsequent response for this driver.
      request = PlaceOS::Driver::Protocol::Request.new("mod-unknown", :result)
      request.seq.should be_nil

      manager.test_process(request)
    end

    it "still routes results that do carry a sequence number" do
      manager = PlaceOS::Driver::Protocol::Management.new("./test_build")

      # Register a request the way `execute` does, then answer it.
      sequence, promise = manager.test_pending_request

      payload = %("pong")
      request = PlaceOS::Driver::Protocol::Request.new("mod-exec", :result, payload: payload)
      request.seq = sequence
      request.code = 200

      manager.test_process(request)

      promise.get.should eq({payload, 200})
    end
  end
end
