require "./helper"

module PlaceOS::Driver::Proxy
  describe Subscriptions do
    it "should subscribe to a channel" do
      in_callback = false
      sub_passed = nil
      message_passed = nil
      channel = Channel(Nil).new

      subs = Proxy::Subscriptions.new
      subscription = subs.channel "test" do |sub, message|
        sub_passed = sub
        message_passed = message
        in_callback = true
        channel.close
      end

      sleep 50.milliseconds

      RedisStorage.with_redis &.publish("placeos/test", "whatwhat")

      channel.receive?

      in_callback.should eq(true)
      message_passed.should eq("whatwhat")
      sub_passed.should eq(subscription)

      subs.terminate
    end

    it "should subscribe directly to a status" do
      in_callback = false
      sub_passed = nil
      message_passed = nil
      channel = Channel(Nil).new

      subs = Proxy::Subscriptions.new
      subscription = subs.subscribe "mod-123", :power do |sub, message|
        sub_passed = sub
        message_passed = message
        in_callback = true
        channel.close
      end
      storage = RedisStorage.new("mod-123")
      storage["power"] = true
      channel.receive?

      in_callback.should eq(true)
      message_passed.should eq("true")
      sub_passed.should eq(subscription)

      storage.delete("power")
      subs.terminate
    end

    it "should indirectly subscribe to a status" do
      in_callback = false
      sub_passed = nil
      message_passed = nil
      channel = Channel(Nil).new

      # Ensure keys don't already exist
      sys_lookup = RedisStorage.new("sys-123", "system")
      lookup_key = "Display/1"
      sys_lookup.delete lookup_key
      storage = RedisStorage.new("mod-1234")
      storage.delete("power")

      subs = Proxy::Subscriptions.new
      subscription = subs.subscribe "sys-123", "Display", 1, :power do |sub, message|
        sub_passed = sub
        message_passed = message
        in_callback = true
        channel.close
      end

      # Subscription should not exist yet - i.e. no lookup
      subscription.module_id.should eq(nil)

      # Create the lookup and signal the change
      sys_lookup[lookup_key] = "mod-1234"
      RedisStorage.with_redis &.publish("lookup-change", "sys-123")

      sleep 50.milliseconds

      # Update the status
      storage["power"] = true

      select
      when channel.receive?
      when timeout(5.seconds)
        raise "timed out waiting for subscription callback"
      end

      subscription.module_id.should eq("mod-1234")
      in_callback.should eq(true)
      message_passed.should eq("true")
      sub_passed.should eq(subscription)

      storage.delete("power")
      sys_lookup.delete lookup_key
      subs.terminate
    end

    # Regression: a `lookup-change` re-maps indirect subscriptions from inside
    # `on_message`, which runs on the reception-loop fiber. If that remap runs
    # inline, `perform_subscribe` -> `wait_for_subscribe_ack` blocks the loop
    # waiting for a SUBSCRIBE ack that only the loop itself can deliver, so it
    # stalls for the full ack timeout per newly-resolved channel and no value
    # is delivered in a timely fashion. With several bindings resolved by a
    # single lookup-change (as a logic driver binding to multiple statuses does)
    # the stall multiplies. The remap must therefore be spawned off the loop.
    it "delivers promptly when a lookup-change resolves several indirect subs" do
      sys_lookup = RedisStorage.new("sys-multi", "system")
      statuses = %w(power input volume)
      storage = RedisStorage.new("mod-multi")
      statuses.each do |s|
        sys_lookup.delete "Display/1"
        storage.delete(s)
      end

      received = {} of String => String
      done = Channel(Nil).new

      subs = Proxy::Subscriptions.new
      statuses.each do |s|
        subs.subscribe "sys-multi", "Display", 1, s do |_sub, message|
          received[s] = message
          done.send(nil) if received.size == statuses.size
        end
      end

      # resolve all three bindings with a single lookup-change
      sys_lookup["Display/1"] = "mod-multi"
      RedisStorage.with_redis &.publish("lookup-change", "sys-multi")
      sleep 100.milliseconds

      statuses.each_with_index { |s, i| storage[s] = i }

      select
      when done.receive?
      when timeout(3.seconds)
        raise "reception loop stalled: only received #{received.keys} within 3s"
      end

      received.size.should eq(statuses.size)

      statuses.each { |s| storage.delete(s) }
      sys_lookup.delete "Display/1"
      subs.terminate
    end
  end
end
