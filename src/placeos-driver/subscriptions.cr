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
      spawn(same_thread: true) { monitor_changes }
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

      # Track indirect subscriptions
      subscriptions = redirections[system_id] ||= [] of PlaceOS::Driver::Subscriptions::IndirectSubscription
      subscriptions << sub
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
      # clean up indirect subscription (if this is one)
      if redirect = redirections[subscription.system_id]?
        sub = redirect.delete(subscription)
        if sub == subscription && redirect.empty?
          redirections.delete(subscription.system_id)
        end
      end

      # clean up subscription tracker
      channel = subscription.subscribe_to
      perform_unsubscribe(subscription, channel) if channel
    end

    private def on_message(channel, message)
      if channel == SYSTEM_ORDER_UPDATE
        remap_indirect(message)
      elsif channel_subscriptions = mutex.synchronize { subscriptions[channel]? }
        channel_subscriptions.each do |subscription|
          spawn { subscription.callback Log, message }
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
          spawn(same_thread: true) { drive_subscriptions(wait, channel, iter, -> { monitor_count }) }

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
            spawn(same_thread: true) do
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
      end

      spawn(same_thread: true) {
        # re-check indirect subscriptions, these are registered by the subscriptions above
        redirections.each_key do |system_id|
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
        sub, chan = details

        begin
          if sub
            redis.subscribe [chan]
          else
            redis.unsubscribe [chan]
          end
        rescue error
          Log.fatal(exception: error) { "redis subscription failed... some components may not function correctly" }
          redis.close
          # Break to stop draining subscription_channel against a dead
          # connection. Every further op would raise "Not connected to
          # Redis server and reconnect=false" and log another FATAL.
          # SimpleRetry will re-establish the subscription loop and
          # re-subscribe to every channel still in the cache.
          break
        end
      end
    end

    private def remap_indirect(system_id)
      if subscriptions = redirections[system_id]?
        subscriptions.each do |sub|
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
        end

        if notify
          wait_for_subscribe_ack(channel) do
            subscription_channel.send({true, channel}) rescue nil
          end
        end

        # notify of current value
        if current_value = subscription.current_value
          spawn(same_thread: true) { subscription.callback(Log, current_value.not_nil!) }
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
