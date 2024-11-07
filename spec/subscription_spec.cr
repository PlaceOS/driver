require "./helper"

module PlaceOS
  class Driver
    describe Subscriptions do
      it "should subscribe to a channel" do
        in_callback = false
        sub_passed = nil
        message_passed = nil
        channel = Channel(Nil).new

        subs = Subscriptions.new

        subscription = subs.channel "test" do |sub, message|
          sub_passed = sub
          message_passed = message
          in_callback = true
          channel.close
        end

        sleep 50.milliseconds

        Subscriptions.new_redis.publish("placeos/test", "whatwhat")

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

        subs = Subscriptions.new
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
        redis = Subscriptions.new_redis

        # Ensure keys don't already exist
        sys_lookup = RedisStorage.new("sys-123", "system")
        lookup_key = "Display/1"
        sys_lookup.delete lookup_key
        storage = RedisStorage.new("mod-1234")
        storage.delete("power")

        subs = Subscriptions.new
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
        redis.publish "lookup-change", "sys-123"

        sleep 50.milliseconds

        # Update the status
        storage["power"] = true
        channel.receive?

        subscription.module_id.should eq("mod-1234")
        in_callback.should eq(true)
        message_passed.should eq("true")
        sub_passed.should eq(subscription)

        # reset
        in_callback = false
        message_passed = nil
        sub_passed = nil
        channel = Channel(Nil).new

        # test signal_status
        storage.signal_status("power")
        channel.receive?
        in_callback.should eq(true)
        message_passed.should eq("true")
        sub_passed.should eq(subscription)

        storage.delete("power")
        sys_lookup.delete lookup_key
        subs.terminate
      end

      it "should recover from a redis outage" do
        in_callback = false
        sub_passed = nil
        message_passed = nil
        channel = Channel(Nil).new
        redis = Subscriptions.new_redis

        # Ensure keys don't already exist
        sys_lookup = RedisStorage.new("sys-1234", "system")
        lookup_key = "Display/1"
        sys_lookup.delete lookup_key
        storage = RedisStorage.new("mod-12345")
        storage.delete("power")

        subs = Subscriptions.new
        subscription = subs.subscribe "sys-1234", "Display", 1, :power do |sub, message|
          sub_passed = sub
          message_passed = message
          in_callback = true
          channel.send(nil)
        end

        # Subscription should not exist yet - i.e. no lookup
        subscription.module_id.should eq(nil)

        # Create the lookup and signal the change
        sys_lookup[lookup_key] = "mod-12345"

        sleep 50.milliseconds

        redis.publish "lookup-change", "sys-12345"

        sleep 50.milliseconds

        # Update the status
        storage["power"] = true
        channel.receive

        subscription.module_id.should eq("mod-12345")
        in_callback.should eq(true)
        message_passed.should eq("true")
        sub_passed.should eq(subscription)

        # Stop the callback loop
        subs.terminate false

        # Give the loop a moment to start up again
        while !subs.running
          sleep 100.milliseconds
        end

        in_callback = false
        sub_passed = nil
        message_passed = nil

        # Update the status
        storage["power"] = false
        channel.receive?

        subscription.module_id.should eq("mod-12345")
        in_callback.should eq(true)
        message_passed.should eq("false")
        sub_passed.should eq(subscription)

        storage.delete("power")
        sys_lookup.delete lookup_key
        subs.terminate
      end
    end
  end
end
