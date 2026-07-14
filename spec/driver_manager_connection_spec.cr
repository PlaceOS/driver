require "./helper"

# Allows a spec to suspend connected-state processing at the point the fiber
# would yield for redis IO, reproducing a slow in-flight transition.
private class RacyManager < PlaceOS::Driver::DriverManager
  property suspend_connection : Channel(Nil)? = nil

  private def check_proxy_usage(driver)
    if channel = @suspend_connection
      @suspend_connection = nil
      channel.receive
    end
    super
  end
end

describe PlaceOS::Driver::DriverManager do
  # Regression: `connection` performs yielding redis operations (proxy hint,
  # then a read-compare-write of the connected status). A disconnect
  # transition suspended mid-processing let a rapid reconnect transition run
  # first — the reconnect saw the status unchanged ("true") and skipped its
  # write, then the stale disconnect resumed and wrote "false". The stored
  # status stayed inverted against the queue state until the next transition.
  it "writes the connected status in transition order when toggled rapidly" do
    PlaceOS::Driver::Protocol.new_instance(Helper.protocol[0]) unless PlaceOS::Driver::Protocol.instance?
    model = PlaceOS::Driver::DriverModel.from_json(%({
      "ip": "localhost",
      "port": 23,
      "udp": false,
      "tls": false,
      "makebreak": false,
      "role": 1,
      "settings": {}
    }))
    manager = RacyManager.new "mod-conn-race", model
    queue = manager.queue
    storage = PlaceOS::Driver::RedisStorage.new("mod-conn-race")

    queue.online = true
    storage["connected"]?.should eq("true")

    # the disconnect transition suspends mid-processing, as happens in
    # production when a redis round-trip is slow
    release = Channel(Nil).new
    manager.suspend_connection = release
    disconnect_processed = Channel(Nil).new
    spawn do
      queue.online = false
      disconnect_processed.send nil
    end
    sleep 10.milliseconds

    # a rapid reconnect arrives while the disconnect is still in flight
    spawn { queue.online = true }
    sleep 10.milliseconds

    # the suspended disconnect transition resumes
    release.send nil
    disconnect_processed.receive
    sleep 50.milliseconds

    # the stored status must match the queue state once processing settles
    queue.online.should be_true
    storage["connected"]?.should eq("true")
  end
end
