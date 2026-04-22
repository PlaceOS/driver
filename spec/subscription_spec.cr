require "./helper"

# Counts FATAL log entries for assertions in specs.
private class FatalCountBackend < ::Log::Backend
  @count = Atomic(Int32).new(0)

  def initialize
    super(::Log::DispatchMode::Direct)
  end

  def write(entry : ::Log::Entry) : Nil
    @count.add(1) if entry.severity.fatal?
  end

  def count : Int32
    @count.get
  end

  def reset : Nil
    @count.set(0)
  end
end

# Mock that bypasses the real connect() in Redis#initialize and raises on
# any subscribe/unsubscribe against a non-empty channel list. Used to
# inject a guaranteed in-fiber failure without disturbing the outer
# subscribe fiber's real connection.
private class FailingRedis < ::Redis
  def initialize
    @host = "localhost"
    @port = 6379
    @ssl = false
    @reconnect = false
    @namespace = ""
  end

  def subscribe(channels : Array(String)) : Void
    raise ::Redis::ConnectionLostError.new("injected failure (not connected)")
  end

  def unsubscribe(channels : Array(String)) : Nil
    return if channels.empty?
    raise ::Redis::ConnectionLostError.new("injected failure (not connected)")
  end

  def close
    # no-op; the real redis held by the outer fiber is unaffected
  end
end

# Subclass that exposes a setter for @redis so tests can swap the redis
# instance used by the subscription_channel consumer fiber.
private class CascadeTestSubscriptions < PlaceOS::Driver::Subscriptions
  def inject_redis(redis : ::Redis) : Nil
    @redis = redis
  end
end

# Mock that lets the outer subscribe block enter a "reception loop" but
# never delivers any acks back — simulates a TCP blackhole between the
# client and redis. close() unblocks the outer subscribe.
private class BlackholeRedis < ::Redis
  getter close_count = Atomic(Int32).new(0)
  @block_channel = Channel(Nil).new

  def initialize
    @host = "localhost"
    @port = 6379
    @ssl = false
    @reconnect = false
    @namespace = ""
  end

  def subscribe(*channels, &block : ::Redis::Subscription ->)
    sub = ::Redis::Subscription.new
    block.call(sub)
    # Stand in for enter_message_reception_loop — block until close.
    @block_channel.receive?
  end

  def subscribe(channels : Array(String)) : Void
    # Silently accept; never deliver a "subscribe" ack to the reception loop.
  end

  def unsubscribe(channels : Array(String)) : Nil
    # Empty channels means "unsubscribe from all" — terminate() relies on
    # this to break the outer subscribe out of its reception loop.
    close if channels.empty?
  end

  def close
    close_count.add(1)
    @block_channel.close
  end
end

# Pre-injects a fresh BlackholeRedis on each iteration so monitor_changes
# never tries to connect to a real redis. Each restart of the loop uses a
# new mock so tests can count restarts via `blackholes.size`.
private class WatchdogTestSubscriptions < PlaceOS::Driver::Subscriptions
  getter blackholes = [] of BlackholeRedis

  def initialize(ack_timeout : Time::Span, heartbeat_interval : Time::Span)
    @redis = next_blackhole
    super(ack_timeout: ack_timeout, heartbeat_interval: heartbeat_interval)
  end

  private def redis
    @redis ||= next_blackhole
  end

  private def next_blackhole : BlackholeRedis
    bh = BlackholeRedis.new
    @blackholes << bh
    bh
  end
end

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

      # Regression: targets the Redis library itself.
      #
      # `Redis#unsubscribe(channels : Array(String))` resets the strategy to
      # SingleStatement after sending UNSUBSCRIBE — even when the connection
      # is still in a subscription loop with other channels active. The next
      # call into `subscribe(channels)` then sees `already_in_subscription_loop?`
      # as false and raises "Must call subscribe with a subscription block".
      #
      # `psubscribe`/`punsubscribe` do not have this problem.
      it "redis: subscribe should still work after unsubscribing from a single channel" do
        redis = Subscriptions.new_redis
        loop_done = Channel(Nil).new

        # Enter the subscription loop in a separate fiber (it blocks).
        spawn(same_thread: true) do
          redis.subscribe("regression-channel-a") do |on|
            on.message { |_, _| }
          end
          loop_done.close
        end

        # Wait for the subscribe to register on the server.
        sleep 100.milliseconds

        # Subscribe to a second channel from outside the block.
        redis.subscribe(["regression-channel-b"])
        sleep 50.milliseconds

        # Unsubscribe from one channel; channel-a remains subscribed so
        # the reception loop must keep running.
        redis.unsubscribe(["regression-channel-b"])
        sleep 50.milliseconds

        # With the bug, the previous unsubscribe reset the strategy and
        # this raises Redis::Error("Must call subscribe with a subscription block").
        begin
          redis.subscribe(["regression-channel-c"])
          sleep 50.milliseconds
        ensure
          # Tear down: unsubscribe from all causes the reception loop to exit.
          redis.unsubscribe([] of String) rescue nil
          loop_done.receive?
          redis.close rescue nil
        end
      end

      # Regression: drives the bug end-to-end through PlaceOS::Driver::Subscriptions.
      #
      # When a session unbinds a single status, the loop should keep running.
      # With the bug, the inner fiber's next subscribe hits the strategy-reset
      # error, the driver logs FATAL and calls redis.close, the outer subscribe
      # fiber dies with "Bad file descriptor", and SimpleRetry restarts the
      # whole monitor_changes loop — observable as `running` flipping false.
      it "should not restart the subscription loop when a single channel is unsubscribed" do
        subs = Subscriptions.new

        while !subs.running
          sleep 50.milliseconds
        end

        sub_a = subs.subscribe "regression-mod-a", :power do |_, _|; end
        sub_b = subs.subscribe "regression-mod-b", :power do |_, _|; end

        # Let both subscribes flush through the inner fiber.
        sleep 200.milliseconds
        subs.running.should eq(true)

        # Track loop restarts. `running` flips false on tear-down and true
        # again once SimpleRetry establishes a fresh subscription loop.
        restart_count = 0
        done = Channel(Nil).new
        spawn(same_thread: true) do
          last_state = subs.running
          until done.closed?
            current = subs.running
            restart_count += 1 if last_state && !current
            last_state = current
            sleep 20.milliseconds
          end
        end

        # Unsubscribe from one channel — this is what triggers the strategy
        # reset inside the redis library.
        subs.unsubscribe(sub_a)

        # Following subscribe is the one that errors inside the inner fiber.
        sub_c = subs.subscribe "regression-mod-c", :power do |_, _|; end

        # Give the inner fiber and SimpleRetry time to react. With the bug
        # we expect at least one restart inside this window; without the
        # bug, the loop stays up.
        sleep 2.seconds

        done.close
        sleep 50.milliseconds

        restart_count.should eq(0)

        # silence "unused" warnings — these subscriptions are part of the scenario
        sub_b.should_not be_nil
        sub_c.should_not be_nil

        subs.terminate
      end

      # Regression: when a redis operation fails inside the subscription_channel
      # consumer fiber, the loop currently only logs + closes redis + keeps
      # draining queued sends. Because `redis.close` sets `@connection = nil`
      # and the Redis client has `reconnect: false`, every subsequent queued op
      # raises "Not connected to Redis server and reconnect=false" and logs
      # another FATAL — producing the cascade of 4 identical fatals within
      # <100ms we saw in the rest-api production logs.
      #
      # Fix: `break` out of the inner loop after `redis.close` so only one
      # FATAL is logged per disconnection event, and the outer SimpleRetry
      # cleanly restarts the subscription loop.
      it "should not cascade FATAL logs when the inner-loop redis op fails" do
        fatal_backend = FatalCountBackend.new
        ::Log.builder.bind("*", ::Log::Severity::Fatal, fatal_backend)

        subs = CascadeTestSubscriptions.new
        while !subs.running
          sleep 50.milliseconds
        end

        # Warm up so the subscription loop is fully established (including
        # the re-subscribe fiber, which would die if @redis is swapped too
        # early because it has no rescue around its `redis.subscribe`).
        3.times do |i|
          subs.subscribe("mod-cascade-#{i}", :power) { |_, _| }
        end
        sleep 200.milliseconds

        fatal_backend.reset

        # Swap @redis for a stub that raises on subscribe. The outer fiber
        # already captured a reference to the original redis via the
        # SubscriptionLoop strategy, so it stays blocked on the real
        # connection and does NOT close subscription_channel. That isolates
        # the inner consumer fiber as the only actor driving the scenario.
        subs.inject_redis(FailingRedis.new)

        # Queue more subscribes than we have capacity to serialize quickly.
        # subscription_channel is unbuffered, so these senders pile up.
        20.times do |i|
          spawn(same_thread: true) do
            subs.subscribe("mod-cascade-more-#{i}", :power) { |_, _| }
          end
        end

        # Let the cascade (or the single break) play out.
        sleep 2.seconds

        # Without the fix: one FATAL per queued op (~5–20 depending on
        # scheduling). With the fix: exactly one FATAL, then break.
        fatal_backend.count.should be <= 2

        # Best-effort cleanup. The outer fiber is still blocked on the real
        # redis; the test's scope is enough to exercise the behavior.
        subs.terminate rescue nil
      end

      # Regression: TCP-blackhole detection. If the subscription connection
      # silently dies (NAT timeout, k8s pod network partition) the outer
      # `@connection.receive` blocks forever — default Linux TCP keepalive
      # is 2 hours. The 3s heartbeat exists already but doesn't verify acks.
      # This spec proves that without a watchdog the loop never restarts;
      # the next change adds the watchdog so that missing SUBSCRIBE acks
      # for `ack_timeout` force a reconnect.
      it "should force-reconnect when no SUBSCRIBE ack arrives within ack_timeout" do
        subs = WatchdogTestSubscriptions.new(
          ack_timeout: 300.milliseconds,
          heartbeat_interval: 50.milliseconds,
        )

        # First iteration must come up before we can assert anything.
        deadline = Time.instant + 5.seconds
        until subs.running
          fail "subscription loop never started" if Time.instant > deadline
          sleep 10.milliseconds
        end

        first_blackhole = subs.blackholes.first

        # Watchdog should close the first BlackholeRedis once the ack
        # window elapses. Allow generous slack on top of ack_timeout.
        deadline = Time.instant + 2.seconds
        until first_blackhole.close_count.get > 0
          fail "watchdog never fired (close not called within 2s)" if Time.instant > deadline
          sleep 20.milliseconds
        end

        first_blackhole.close_count.get.should be > 0

        # SimpleRetry should bring up a fresh iteration with a NEW mock.
        deadline = Time.instant + 5.seconds
        until subs.blackholes.size >= 2
          fail "loop did not restart with a new redis" if Time.instant > deadline
          sleep 20.milliseconds
        end

        subs.blackholes.size.should be >= 2

        subs.terminate rescue nil
      end
    end
  end
end
