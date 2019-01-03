
class EngineDriver::Subscriptions
  SYSTEM_ORDER_UPDATE = "lookup\x02change"

  def initialize
    @terminated = false

    # Channel name to subscriptions
    @subscriptions = {} of String => Array(Subscription)

    # System ID to subscription keys
    @mutex = Mutex.new
    @redirections = {} of String => String

    # TODO:: provide redis connection details
    @redis_subscribe = Redis.new
    spawn do
      monitor_changes
    end
  end

  def terminate
    @terminated = true
    @redis_subscribe.unsubscribe
  end

  # Self reference subscription
  def subscribe(module_id, status, &callback) : EngineDriver::Subscriptions::DirectSubscription
    sub = EngineDriver::Subscriptions::DirectSubscription.new(module_id.to_s, status.to_s, &callback)
    if channel = sub.subscribe_to
      @redis_subscribe.subscribe channel
      if current_value = sub.current_value
        spawn { sub.callback(current_value) } if current_value
      end
    end
    sub
  end

  # Abstract subscription
  def subscribe(system_id, module_name, index, status, &callback) : EngineDriver::Subscriptions::IndirectSubscription
    sub = EngineDriver::Subscriptions::IndirectSubscription.new(system_id.to_s, module_name.to_s, index.to_i, status.to_s, &callback)
    @mutex.synchronize do
      if channel = sub.subscribe_to
        subscriptions = @redirections[system_id] ||= [] of String
        subscriptions << channel

        @redis_subscribe.subscribe channel
        if current_value = sub.current_value
          spawn { sub.callback(current_value) } if current_value
        end
      end
    end
    sub
  end

  # Provide generic channels for modules to communicate over
  def channel(name, &callback) : EngineDriver::Subscriptions::ChannelSubscription
    sub = EngineDriver::Subscriptions::ChannelSubscription.new(name.to_s, &callback)
    if channel = sub.subscribe_to
      @redis_subscribe.subscribe channel
    end
    sub
  end

  def unsubscribe(subscription : EngineDriver::Subscriptions::ChannelSubscription | EngineDriver::Subscriptions::DirectSubscription) : nil
    channel = subscription.subscribe_to
    if channel
      if subscriptions = @subscriptions[channel]?
        sub = subscriptions.delete(subscription)
        if sub == subscription && subscriptions.empty?
          @subscriptions.delete(channel)
          @redis_subscribe.unsubscribe channel
        end
      end
    end
  end

  def unsubscribe(subscription : EngineDriver::Subscriptions::IndirectSubscription) : nil
    @mutex.synchronize do
      channel = subscription.subscribe_to
      if channel
        if subscriptions = @subscriptions[channel]?
          sub = subscriptions.delete(subscription)
          if sub == subscription && subscriptions.empty?
            @subscriptions.delete(channel)
            @redis_subscribe.unsubscribe channel
          end
        end
      end
    end
  end

  private def on_message(channel, message)
    if channel == SYSTEM_ORDER_UPDATE

    else

    end
  end

  private def monitor_changes
    retry max_interval: 5.seconds do
      @redis_subscribe.subscribe(SYSTEM_ORDER_UPDATE) do |on|
        on.message { |c, m| on_message(c, m) }

        # TODO:: re-subscribe to existing subscriptions here

      end

      raise "reconnect" unless @terminated
    end
  end
end
