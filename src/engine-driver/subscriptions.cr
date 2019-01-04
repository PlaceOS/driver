
class EngineDriver::Subscriptions
  SYSTEM_ORDER_UPDATE = "lookup\x02change"

  def initialize
    @terminated = false

    # Mutex for indirect subscriptions as it involves two hashes, a redis lookup
    # and the possibility of an index change. The redis lookup pauses the
    # current fibre allowing for a race condition without a lock in place
    @mutex = Mutex.new

    # Channel name to subscriptions
    @subscriptions = {} of String => Array(EngineDriver::Subscriptions::Subscription)

    # System ID to subscriptions
    @redirections = {} of String => Array(EngineDriver::Subscriptions::IndirectSubscription)

    # TODO:: provide redis connection details
    @redis_subscribe = Redis.new
    spawn { monitor_changes }
  end

  def terminate
    @terminated = true

    # Unsubscribe with no arguments unsubscribes from all, this will terminate
    # the subscription loop, allowing monitor_changes to return
    @redis_subscribe.unsubscribe
  end

  # Self reference subscription
  def subscribe(module_id, status, &callback) : EngineDriver::Subscriptions::DirectSubscription
    sub = EngineDriver::Subscriptions::DirectSubscription.new(module_id.to_s, status.to_s, &callback)
    perform_subscribe(sub)
    sub
  end

  # Abstract subscription
  def subscribe(system_id, module_name, index, status, &callback) : EngineDriver::Subscriptions::IndirectSubscription
    sub = EngineDriver::Subscriptions::IndirectSubscription.new(system_id.to_s, module_name.to_s, index.to_i, status.to_s, &callback)

    @mutex.synchronize {
      # Track indirect subscriptions
      subscriptions = @redirections[system_id] ||= [] of EngineDriver::Subscriptions::IndirectSubscription
      subscriptions << sub
      perform_subscribe(sub)
    }

    sub
  end

  # Provide generic channels for modules to communicate over
  def channel(name, &callback) : EngineDriver::Subscriptions::ChannelSubscription
    sub = EngineDriver::Subscriptions::ChannelSubscription.new(name.to_s, &callback)
    if channel = sub.subscribe_to
      # update the subscription cache
      if subscriptions = @subscriptions[channel]?
        subscriptions << sub
      else
        subscriptions = @subscriptions[channel] = [] of EngineDriver::Subscriptions::Subscription
        subscriptions << sub
        @redis_subscribe.subscribe channel
      end
    end
    sub
  end

  def unsubscribe(subscription : EngineDriver::Subscriptions::Subscription) : nil
    @mutex.synchronize {
      # clean up indirect subscription (if this is one)
      if redirect = @redirections[subscription.system_id]?
        sub = redirect.delete(subscription)
        if sub == subscription && redirect.empty?
          @redirections.delete(subscription.system_id)
        end
      end

      # clean up subscription tracker
      channel = subscription.subscribe_to
      perform_unsubscribe(subscription, channel) if channel
    }
  end

  private def on_message(channel, message)
    if channel == SYSTEM_ORDER_UPDATE
      @mutex.synchronize { remap_indirect(message) }
    elsif subscriptions = @subscriptions[channel]?
      subscriptions.each do |subscription|
        subscription.callback message
      end
    else
      # TODO:: log issue, subscribed to channel but no subscriptions
      puts "WARN: received message for channel with no subscription!"
      puts "Channel: #{channel}\nMessage: #{message}"
    end
  end

  private def monitor_changes
    retry max_interval: 5.seconds do
      @redis_subscribe.subscribe(SYSTEM_ORDER_UPDATE) do |on|
        on.message { |c, m| on_message(c, m) }

        # This will run on redis reconnect
        @mutex.synchronize {
          # re-subscribe to existing subscriptions here
          @subscriptions.each_key do |channel|
            @redis_subscribe.subscribe channel
          end

          # re-check indirect subscriptions
          @redirections.each_key do |system_id|
            remap_indirect(system_id)
          end

          # TODO:: check for any value changes
          # disconnect might have been a network partition and an update may
          # have occurred during this time gap
        }
      end

      raise "reconnect" unless @terminated
    end
  end

  private def remap_indirect(system_id)
    if subscriptions = @redirections[system_id]
      subscriptions.each do |sub|
        subscribed = false

        # Check if currently mapped
        if mod_id = sub.module_id
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
      if subscriptions = @subscriptions[channel]?
        subscriptions << subscription
      else
        subscriptions = @subscriptions[channel] = [] of EngineDriver::Subscriptions::Subscription
        subscriptions << subscription
        @redis_subscribe.subscribe channel
      end

      # notify of current value
      if current_value = subscription.current_value
        spawn { subscription.callback(current_value) }
      end
    end
  end

  private def perform_unsubscribe(subscription : EngineDriver::Subscriptions::Subscription, channel : String)
    if subscriptions = @subscriptions[channel]?
      sub = subscriptions.delete(subscription)
      if sub == subscription && subscriptions.empty?
        @subscriptions.delete(channel)
        @redis_subscribe.unsubscribe channel
      end
    end
  end
end
