require "log_helper"
require "redis"
require "simple_retry"

require "./constants"

# TODO:: we need to be scheduling these onto the correct thread
class PlaceOS::Driver
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

    private property subscription_channel : Channel(Tuple(Bool, String)) = Channel(Tuple(Bool, String)).new

    def initialize(module_id : String = "")
      spawn(same_thread: true) { monitor_changes }
    end

    def terminate(terminate = true) : Nil
      self.terminated = terminate
      @running = false

      # Unsubscribe with no arguments unsubscribes from all, this will terminate
      # the subscription loop, allowing monitor_changes to return
      redis.unsubscribe([] of String)
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
        # update the subscription cache
        if channel_subscriptions = subscriptions[channel]?
          channel_subscriptions << sub
        else
          channel_subscriptions = subscriptions[channel] = [] of PlaceOS::Driver::Subscriptions::Subscription
          channel_subscriptions << sub
          subscription_channel.send({true, channel})
        end
      end

      sub
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
      elsif channel_subscriptions = subscriptions[channel]?
        channel_subscriptions.each do |subscription|
          spawn { subscription.callback Log, message }
        end
      else
        # subscribed to channel but no subscriptions
        Log.warn { "received message for channel with no subscription!\nChannel: #{channel}\nMessage: #{message}" }
      end
    end

    private def monitor_changes
      SimpleRetry.try_to(
        base_interval: 1.second,
        max_interval: 5.seconds,
        randomise: 500.milliseconds
      ) do
        wait = Channel(Nil).new
        begin
          # This will run on redis reconnect
          # We can't have this run in the subscribe block as the subscribe block
          # needs to return before we subscribe to further channels
          spawn(same_thread: true) {
            wait.receive?
            # re-subscribe to existing subscriptions here
            # NOTE:: sending an empty array errors
            redis.subscribe(subscriptions.keys) if subscriptions.size > 0

            spawn(same_thread: true) {
              # re-check indirect subscriptions
              redirections.each_key do |system_id|
                remap_indirect(system_id)
              end
            }

            @running = true

            # TODO:: check for any value changes
            # disconnect might have been a network partition and an update may
            # have occurred during this time gap

            while details = subscription_channel.receive?
              sub, chan = details

              begin
                SimpleRetry.try_to(
                  max_attempts: 4,
                  base_interval: 20.milliseconds,
                  max_interval: 1.seconds,
                  randomise: 80.milliseconds
                ) do
                  if sub
                    redis.subscribe [chan]
                  else
                    redis.unsubscribe [chan]
                  end
                end
              rescue error
                logger.fatal(exception: error) { "redis subscription failed... some components may not function correctly" }
              end
            end
          }

          # The reason for all the sync and spawns is that the first subscribe
          # requires a block and subsequent ones throw an error with a block.
          # NOTE:: this version of subscribe only supports splat arguments
          redis.subscribe(SYSTEM_ORDER_UPDATE) do |on|
            on.message { |c, m| on_message(c, m) }
            spawn(same_thread: true) { wait.close }
          end

          raise "no subscriptions, restarting loop" unless terminated?
        rescue e
          Log.warn(exception: e) { "redis subscription loop exited" }
          raise e
        ensure
          wait.close
          subscription_channel.close
          self.subscription_channel = Channel(Tuple(Bool, String)).new

          @running = false

          # We need to re-create the subscribe object for our sanity
          handle_disconnect unless terminated?
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
            if current_channel && current_channel != new_channel
              perform_unsubscribe(sub, current_channel)
            else
              subscribed = true
            end
          end

          perform_subscribe(sub) if !subscribed
        end
      end
    end

    private def perform_subscribe(subscription)
      if channel = subscription.subscribe_to
        # update the subscription cache
        if channel_subscriptions = subscriptions[channel]?
          channel_subscriptions << subscription
        else
          channel_subscriptions = subscriptions[channel] = [] of PlaceOS::Driver::Subscriptions::Subscription
          channel_subscriptions << subscription
          subscription_channel.send({true, channel})
        end

        # notify of current value
        if current_value = subscription.current_value
          spawn(same_thread: true) { subscription.callback(Log, current_value.not_nil!) }
        end
      end
    end

    private def perform_unsubscribe(subscription : PlaceOS::Driver::Subscriptions::Subscription, channel : String)
      if channel_subscriptions = subscriptions[channel]?
        sub = channel_subscriptions.delete(subscription)
        if sub == subscription && subscriptions.empty?
          channel_subscriptions.delete(channel)
          subscription_channel.send({false, channel})
        end
      end
    end

    @redis_cluster : Redis::Client? = nil
    @redis : Redis? = nil

    protected def self.new_clustered_redis
      Redis::Client.boot(ENV["REDIS_URL"]? || "redis://localhost:6379")
    end

    private def redis_cluster
      @redis_cluster_client ||= Subscriptions.new_clustered_redis
    end

    protected def self.new_redis(cluster : Redis::Client = new_clustered_redis) : Redis
      client = new_clustered_redis.connect!

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
        cluster.close!
        cluster.connect!.as(Redis)
      end
    end

    private def handle_disconnect
      @redis = Subscriptions.new_redis(redis_cluster)
    end
  end
end

require "./subscriptions/*"
