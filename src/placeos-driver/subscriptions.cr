require "redis"
require "simple_retry"

require "./constants"

class PlaceOS::Driver
  # :nodoc:
  # TODO:: we need to be scheduling these onto the correct thread
  class Subscriptions
    SYSTEM_ORDER_UPDATE = "lookup-change"
    Log                 = ::Log.for(self, ::Log::Severity::Info)

    # Mutex for indirect subscriptions as it involves two hashes, a redis lookup
    # and the possibility of an index change. The redis lookup pauses the
    # current fibre allowing for a race condition without a lock in place
    private getter mutex = Mutex.new

    # Channel name to subscriptions
    private getter subscriptions : Hash(String, Array(PlaceOS::Driver::Subscriptions::Subscription)) = {} of String => Array(PlaceOS::Driver::Subscriptions::Subscription)

    # System ID to subscriptions
    private getter redirections : Hash(String, Array(PlaceOS::Driver::Subscriptions::IndirectSubscription)) = {} of String => Array(PlaceOS::Driver::Subscriptions::IndirectSubscription)

    # Subscriptions that have NOT yet received their first value, keyed by
    # channel. A redis SUBSCRIBE only delivers values published *after* it is
    # registered, so a value already in the hash (or one published into the
    # registration gap during startup / reconnect) would otherwise never reach
    # a brand new binding. Entries are added on subscribe and removed the moment
    # the binding receives any value (initial read in #notify_awaiting or a
    # pub/sub message in #on_message) or is unsubscribed — so this only ever
    # holds bindings still legitimately waiting for a first value and never
    # accumulates. Guarded by `mutex`.
    private getter awaiting_value : Hash(String, Array(PlaceOS::Driver::Subscriptions::Subscription)) = {} of String => Array(PlaceOS::Driver::Subscriptions::Subscription)

    # Subscriptions need their own seperate client
    private def redis
      @redis ||= Subscriptions.new_redis(redis_cluster)
    end

    # Is the subscription loop running?
    getter running : Bool = false

    # Is the subscription terminated
    private property? terminated = false

    # subscription_channel feeds drain_subscription_channel. It MUST stay
    # unbuffered: the implicit back-pressure on `perform_subscribe.send` is
    # what guarantees `subscribe(...)` doesn't return until drain has sent
    # SUBSCRIBE to Redis. Buffering breaks that contract — callers proceed
    # before the Redis subscription is registered, and any PUBLISH that
    # follows is lost (Redis pub/sub has no replay).
    private property subscription_channel : Channel(Tuple(Bool, String)) = Channel(Tuple(Bool, String)).new

    # Per-channel "waiting for SUBSCRIBE ack" map. perform_subscribe parks
    # on the ack channel after sending; the outer subscribe's on.subscribe
    # handler signals it. Guarantees subscribe(...) doesn't return until
    # Redis has actually registered the subscription, so an immediately-
    # following PUBLISH is delivered to us. Guarded by `mutex`.
    @pending_subscribes : Hash(String, Channel(Nil)) = {} of String => Channel(Nil)

    # If we don't see a SUBSCRIBE ack within this window, log and continue
    # — the subscription is still in the hash and will be re-registered on
    # the next monitor_changes iteration.
    SUBSCRIBE_ACK_TIMEOUT = 2.seconds

    # `ack_timeout` and `heartbeat_interval` configure the watchdog that
    # detects a stalled (TCP-blackholed) subscription connection. Each
    # `heartbeat_interval` we re-SUBSCRIBE to SYSTEM_ORDER_UPDATE; if the
    # server hasn't acknowledged any subscribe in `ack_timeout`, we close
    # the redis client and let SimpleRetry establish a fresh connection.
    @last_ack : Time::Instant = Time.instant

    def initialize(@ack_timeout : Time::Span = 15.seconds, @heartbeat_interval : Time::Span = 3.seconds)
      spawn(same_thread: true, name: "sub-monitor") { monitor_changes }
    end

    def terminate(terminate = true) : Nil
      self.terminated = terminate
      @running = false

      # Unsubscribe with no arguments unsubscribes from all, this will terminate
      # the subscription loop, allowing monitor_changes to return.
      # Only act on an existing connection — otherwise the lazy getter would
      # build a fresh cluster + subscription client just to send UNSUBSCRIBE
      # and leak the whole stack on the way out.
      @redis.try(&.unsubscribe([] of String))
    end

    # Self reference subscription
    def subscribe(module_id, status, &callback : (PlaceOS::Driver::Subscriptions::DirectSubscription, String) ->) : PlaceOS::Driver::Subscriptions::DirectSubscription
      sub = PlaceOS::Driver::Subscriptions::DirectSubscription.new(module_id.to_s, status.to_s, &callback)
      perform_subscribe(sub)
      sub
    end

    # Abstract subscription
    def subscribe(system_id, module_name, index, status, &callback : (PlaceOS::Driver::Subscriptions::IndirectSubscription, String) ->) : PlaceOS::Driver::Subscriptions::IndirectSubscription
      sub = PlaceOS::Driver::Subscriptions::IndirectSubscription.new(system_id.to_s, module_name.to_s, index.to_i, status.to_s, &callback)

      # Track indirect subscriptions. `redirections` is shared with the
      # reception-loop / sub-remap fibers, so the mutation must be guarded;
      # perform_subscribe stays OUTSIDE the lock as it re-locks the mutex.
      mutex.synchronize do
        (redirections[system_id] ||= [] of PlaceOS::Driver::Subscriptions::IndirectSubscription) << sub
      end
      perform_subscribe(sub)

      sub
    end

    # Provide generic channels for modules to communicate over
    def channel(name, &callback : (PlaceOS::Driver::Subscriptions::ChannelSubscription, String) -> Nil) : PlaceOS::Driver::Subscriptions::ChannelSubscription
      sub = PlaceOS::Driver::Subscriptions::ChannelSubscription.new(name.to_s, &callback)
      if channel = sub.subscribe_to
        notify = false

        # update the subscription cache
        mutex.synchronize do
          if channel_subscriptions = subscriptions[channel]?
            channel_subscriptions << sub
          else
            channel_subscriptions = subscriptions[channel] = [] of PlaceOS::Driver::Subscriptions::Subscription
            channel_subscriptions << sub
            notify = true
          end
        end

        if notify
          wait_for_subscribe_ack(channel) do
            subscription_channel.send({true, channel}) rescue nil
          end
        end
      end

      sub
    end

    # Sends the subscribe request (via the supplied block) and blocks until
    # the outer subscribe's on.subscribe handler signals that Redis has
    # acked SUBSCRIBE for this channel — or `SUBSCRIBE_ACK_TIMEOUT`
    # elapses, in which case the subscription is still in the hash and
    # will be re-registered on the next monitor_changes iteration.
    private def wait_for_subscribe_ack(channel : String, &) : Nil
      waiter = Channel(Nil).new(1)
      mutex.synchronize { @pending_subscribes[channel] = waiter }
      begin
        yield
        select
        when waiter.receive?
          # Redis has registered the subscription; safe to return.
        when timeout(SUBSCRIBE_ACK_TIMEOUT)
          Log.debug { "no SUBSCRIBE ack for #{channel} within #{SUBSCRIBE_ACK_TIMEOUT}; will retry on next loop iteration" }
        end
      ensure
        mutex.synchronize { @pending_subscribes.delete(channel) }
      end
    end

    def unsubscribe(subscription : PlaceOS::Driver::Subscriptions::Subscription) : Nil
      # clean up indirect subscription (if this is one). Guarded — `redirections`
      # is shared with the reception-loop / sub-remap fibers.
      mutex.synchronize do
        if redirect = redirections[subscription.system_id]?
          sub = redirect.delete(subscription)
          if sub == subscription && redirect.empty?
            redirections.delete(subscription.system_id)
          end
        end
      end

      # clean up subscription tracker
      channel = subscription.subscribe_to
      perform_unsubscribe(subscription, channel) if channel
    end

    private def on_message(channel, message)
      if channel == SYSTEM_ORDER_UPDATE
        remap_indirect(message)
      elsif channel_subscriptions = mutex.synchronize { awaiting_value.delete(channel); subscriptions[channel]? }
        # every binding on this channel is receiving a value, so none are
        # awaiting their first value any more (delete handled above)
        channel_subscriptions.each do |subscription|
          spawn(name: "sub-callback") { subscription.callback Log, message }
        end
      else
        # subscribed to channel but no subscriptions
        Log.warn { "received message for channel with no subscription!\nChannel: #{channel}\nMessage: #{message}" }
      end
    end

    private def monitor_changes
      monitor_count = 0

      SimpleRetry.try_to(
        base_interval: 1.second,
        max_interval: 5.seconds,
        randomise: 500.milliseconds
      ) do
        return if terminated?
        monitor_count += 1
        subscribe_count = monitor_count
        wait = Channel(Nil).new
        # Reset the watchdog clock so the heartbeat has a full ack_timeout
        # window to receive its first SUBSCRIBE ack on this iteration.
        @last_ack = Time.instant
        begin
          # This will run on redis reconnect
          # We can't have this run in the subscribe block as the subscribe block
          # needs to return before we subscribe to further channels
          iter = monitor_count
          channel = subscription_channel
          spawn(same_thread: true, name: "sub-drive") { drive_subscriptions(wait, channel, iter, -> { monitor_count }) }

          # The reason for all the sync and spawns is that the first subscribe
          # requires a block and subsequent ones throw an error with a block.
          # NOTE:: this version of subscribe only supports splat arguments
          redis.subscribe(SYSTEM_ORDER_UPDATE) do |on|
            raise "redis reconnect detected" if subscribe_count != monitor_count
            subscribe_count += 1

            # Watchdog: every SUBSCRIBE ack from the server stamps @last_ack.
            # Combined with the periodic re-SUBSCRIBE below, this gives us
            # liveness — if no acks for `ack_timeout` we know the connection
            # is blackholed and force a reconnect.
            on.subscribe do |chan, _count|
              @last_ack = Time.instant
              # Wake any caller of perform_subscribe / channel waiting for
              # confirmation that Redis has registered this channel.
              if waiter = mutex.synchronize { @pending_subscribes[chan]? }
                waiter.send(nil) rescue nil
              end
            end
            on.message { |c, m| on_message(c, m) }
            spawn(same_thread: true, name: "sub-heartbeat") do
              instance = monitor_count
              wait.close
              loop do
                sleep @heartbeat_interval
                break if instance != monitor_count
                if Time.instant - @last_ack > @ack_timeout
                  Log.warn { "no subscribe ack within #{@ack_timeout.total_seconds}s — forcing reconnect" }
                  redis.close
                  break
                end
                # rescue break: if the channel was just closed by the
                # ensure block (loop restart), exit cleanly rather than
                # crashing the fiber with an unhandled ClosedError.
                subscription_channel.send({true, SYSTEM_ORDER_UPDATE}) rescue break
              end
            end
          end

          raise "no subscriptions, restarting loop" unless terminated?
        rescue e
          Log.warn(exception: e) { "redis subscription loop exited" }
          raise e
        ensure
          wait.close

          mutex.synchronize do
            subscription_channel.close
            self.subscription_channel = Channel(Tuple(Bool, String)).new
          end

          @running = false

          @redis.try(&.close) rescue nil
          @redis = nil
          @redis_cluster.try(&.close!) rescue nil
          @redis_cluster = nil
        end
      end
    end

    # Drives re-subscription and the subscribe/unsubscribe drain loop for a
    # single iteration of `monitor_changes`. Extracted so its branches don't
    # bloat the parent method's cyclomatic complexity.
    #
    # `wait` is closed when the outer SUBSCRIBE has either entered its block
    # (happy path, fired by the heartbeat fiber) or aborted before doing so
    # (ensure path). The `current_iter` lambda lets us notice if SimpleRetry
    # has moved on to a new iteration while we were scheduling.
    private def drive_subscriptions(wait : Channel(Nil), channel : Channel(Tuple(Bool, String)), iter : Int32, current_iter : -> Int32) : Nil
      wait.receive?
      # If the outer subscribe failed before entering its block, the
      # heartbeat fiber never fires wait.close — the ensure block does.
      # In that case @redis has been closed/nilled already and we must
      # not proceed, otherwise the lazy getter would build a fresh
      # client to subscribe on and then strand it waiting on the
      # replaced subscription_channel.
      return if terminated? || iter != current_iter.call || @redis.nil?

      # re-subscribe to existing subscriptions here
      # NOTE:: sending an empty array errors
      keys = mutex.synchronize { subscriptions.keys }
      if keys.size > 0
        begin
          redis.subscribe(keys)
        rescue error
          Log.warn(exception: error) { "failed to re-subscribe on reconnect" }
          # Close redis so the outer SUBSCRIBE on SYSTEM_ORDER_UPDATE fails
          # and SimpleRetry restarts monitor_changes. Otherwise we'd be stuck
          # with user channels missing from Redis, drain_subscription_channel
          # never starting, and perform_subscribe blocking on the unbuffered
          # path — until the watchdog ack-timeout fires (15s by default).
          redis.close rescue nil
          return
        end

        # A PUBLISH issued while the connection was down is gone (redis pub/sub
        # has no replay), so any binding that never received its first value
        # would stay stale. Re-deliver only to those still-awaiting bindings —
        # not every channel — to avoid a reconnect-time flood of HGETs and
        # duplicate callbacks for already-initialised bindings.
        mutex.synchronize { awaiting_value.keys }.each { |chan| notify_awaiting(chan) }
      end

      spawn(same_thread: true, name: "sub-remap") {
        # re-check indirect subscriptions, these are registered by the
        # subscriptions above. Snapshot the keys under the lock (mirroring the
        # `subscriptions.keys` idiom above) so we never iterate the live hash
        # while a user fiber mutates it; remap_indirect re-locks the mutex
        # internally so it must run outside the synchronized block.
        mutex.synchronize { redirections.keys }.each do |system_id|
          remap_indirect(system_id)
        end
      }

      @running = true

      # `channel` is captured locally — the ensure block replaces
      # `subscription_channel` after closing it, and reading via the getter
      # would silently switch us onto a brand new channel with no writers,
      # stranding this fiber (and its redis connection).
      drain_subscription_channel(channel)
    end

    private def drain_subscription_channel(channel : Channel(Tuple(Bool, String))) : Nil
      while details = channel.receive?
        subscribe, chan = details

        begin
          if subscribe
            redis.subscribe [chan]
            # SUBSCRIBE is now registered with redis: deliver the current value
            # to any binding on this channel that hasn't received one yet. Done
            # here (post-registration) so a value published into the gap before
            # registration isn't lost.
            notify_awaiting(chan)
          else
            # Guarded unsubscribe: a concurrent re-subscribe (a different fiber)
            # may have re-added this channel after the {false, chan} was queued.
            # Tearing it down here would leave redis unsubscribed while the cache
            # still holds live bindings, silently dropping their future updates.
            # Only unsubscribe when the cache truly has no subscriptions for it.
            redis.unsubscribe [chan] unless mutex.synchronize { subscriptions.has_key?(chan) }
          end
        rescue error
          Log.fatal(exception: error) { "redis subscription failed... some components may not function correctly" }
          # `rescue nil` (matching the other close sites): on a TLS connection
          # close can itself raise OpenSSL::SSL::Error, which would escape this
          # fiber and skip the break below.
          redis.close rescue nil
          # Break to stop draining subscription_channel against a dead
          # connection. Every further op would raise "Not connected to
          # Redis server and reconnect=false" and log another FATAL.
          # SimpleRetry will re-establish the subscription loop and
          # re-subscribe to every channel still in the cache.
          break
        end
      end
    end

    # Delivers the current value to every subscription on `channel` that is
    # still awaiting its first value, then drops the ones it delivered to. Must
    # be called *after* redis has registered the SUBSCRIBE for the channel so a
    # value already present in the hash is surfaced without a future publish.
    # The subscriber list is snapshotted under the mutex (`.dup`) so the
    # suspending HGET in `current_value` runs without holding the lock. No-op
    # for SYSTEM_ORDER_UPDATE (never tracked) and for channels whose bindings
    # have all received a value.
    private def notify_awaiting(channel : String) : Nil
      pending = mutex.synchronize { awaiting_value[channel]?.try(&.dup) }
      return unless pending

      pending.each do |subscription|
        # The HGET in current_value suspends the fiber, so it must run OUTSIDE
        # the lock. A pub/sub message for this channel can therefore arrive
        # mid-read and on_message will deliver + clear `awaiting_value` for it.
        next unless current_value = subscription.current_value
        value = current_value

        # `awaiting_value` membership is the single claim token shared with
        # on_message: re-check under the lock and only deliver if this binding
        # is STILL awaiting its first value. Whichever of us removes it wins, so
        # the first value reaches the binding exactly once (no double-delivery,
        # and no stale HGET value landing after a newer published one).
        claimed = mutex.synchronize do
          if (list = awaiting_value[channel]?) && list.delete(subscription)
            awaiting_value.delete(channel) if list.empty?
            true
          else
            false
          end
        end

        spawn(same_thread: true, name: "sub-initial") { subscription.callback(Log, value) } if claimed
      end
    end

    private def remap_indirect(system_id)
      # Snapshot the array under the lock — it is shared with subscribe /
      # unsubscribe on user fibers. perform_subscribe / perform_unsubscribe
      # below re-lock the mutex, so they must run outside the synchronized block.
      if subs = mutex.synchronize { redirections[system_id]?.try(&.dup) }
        subs.each do |sub|
          subscribed = false

          # Check if currently mapped
          if sub.module_id
            current_channel = sub.subscribe_to
            sub.reset
            new_channel = sub.subscribe_to

            # Unsubscribe if channel changed
            if current_channel
              if current_channel != new_channel
                perform_unsubscribe(sub, current_channel)
              else
                subscribed = true
              end
            end
          end

          perform_subscribe(sub) unless subscribed
        end
      end
    end

    private def perform_subscribe(subscription)
      if channel = subscription.subscribe_to
        notify = false

        mutex.synchronize do
          # update the subscription cache
          if channel_subscriptions = subscriptions[channel]?
            channel_subscriptions << subscription
          else
            channel_subscriptions = subscriptions[channel] = [] of PlaceOS::Driver::Subscriptions::Subscription
            channel_subscriptions << subscription
            notify = true
          end

          # track until this binding has received its first value
          (awaiting_value[channel] ||= [] of PlaceOS::Driver::Subscriptions::Subscription) << subscription
        end

        if notify
          wait_for_subscribe_ack(channel) do
            subscription_channel.send({true, channel}) rescue nil
          end
          # the current value is delivered by the drain once redis has
          # registered the SUBSCRIBE for this new channel (see notify_awaiting
          # in drain_subscription_channel) so a value published into the
          # registration gap isn't missed.
        else
          # the channel is already registered with redis (another binding
          # subscribed first) and the drain won't fire for this one, so deliver
          # the current value inline.
          notify_awaiting(channel)
        end
      end
    end

    private def perform_unsubscribe(subscription : PlaceOS::Driver::Subscriptions::Subscription, channel : String)
      notify = false

      mutex.synchronize do
        if channel_subscriptions = subscriptions[channel]?
          channel_subscriptions.delete(subscription)
          if channel_subscriptions.empty?
            subscriptions.delete(channel)
            notify = true
          end
        end

        # drop from the awaiting-first-value tracker so it can't leak a binding
        # that was unsubscribed before it ever received a value
        if awaiting = awaiting_value[channel]?
          awaiting.delete(subscription)
          awaiting_value.delete(channel) if awaiting.empty?
        end
      end

      if notify
        subscription_channel.send({false, channel}) rescue nil
      end
    end

    @redis_cluster : Redis::Client? = nil
    @redis : Redis? = nil

    protected def self.new_clustered_redis
      Redis::Client.boot(ENV["REDIS_URL"]? || "redis://localhost:6379", reconnect: false, command_timeout: 10.seconds)
    end

    private def redis_cluster
      @redis_cluster ||= Subscriptions.new_clustered_redis
    end

    protected def self.new_redis(cluster : Redis::Client = new_clustered_redis) : Redis
      client = cluster.connect!

      if client.is_a?(::Redis::Cluster::Client)
        client.cluster_info.each_nodes do |node_info|
          begin
            return client.new_redis(node_info.addr.host, node_info.addr.port)
          rescue
            # Ignore nodes we cannot connect to
          end
        end

        # Could not connect to any nodes in cluster
        raise Redis::ConnectionError.new
      else
        client.as(Redis)
      end
    end
  end
end

require "./subscriptions/*"
