require "../subscriptions"

class EngineDriver::Proxy::Subscriptions
  def initialize(@subscriber : EngineDriver::Subscriptions = EngineDriver::Subscriptions.new)
    @subscriptions = [] of EngineDriver::Subscriptions::Subscription
    @terminated = false
  end

  def terminate
    @terminated = true
    clear
  end

  def clear : Nil
    subs = @subscriptions
    @subscriptions = [] of EngineDriver::Subscriptions::Subscription
    subs.each do |subscription|
      @subscriber.unsubscribe(subscription)
    end
  end

  def unsubscribe(subscription : EngineDriver::Subscriptions::Subscription)
    @subscriptions.delete(subscription)
    @subscriber.unsubscribe(subscription)
  end

  def channel(name, &callback : (EngineDriver::Subscriptions::ChannelSubscription, String) -> Nil) : EngineDriver::Subscriptions::ChannelSubscription
    raise "subscription proxy terminated" if @terminated
    sub = @subscriber.channel(name, &callback)
    @subscriptions << sub
    sub
  end

  def subscribe(system_id, module_name, index, status, &callback : (EngineDriver::Subscriptions::IndirectSubscription, String) -> Nil) : EngineDriver::Subscriptions::IndirectSubscription
    raise "subscription proxy terminated" if @terminated
    sub = @subscriber.subscribe(system_id, module_name, index, status, &callback)
    @subscriptions << sub
    sub
  end

  def subscribe(module_id, status, &callback : (EngineDriver::Subscriptions::DirectSubscription, String) -> Nil) : EngineDriver::Subscriptions::DirectSubscription
    raise "subscription proxy terminated" if @terminated
    sub = @subscriber.subscribe(module_id, status, &callback)
    @subscriptions << sub
    sub
  end
end
