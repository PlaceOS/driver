require "../subscriptions"

class ACAEngine::Driver::Proxy::Subscriptions
  def initialize(@subscriber : ACAEngine::Driver::Subscriptions = ACAEngine::Driver::Subscriptions.new)
    @subscriptions = [] of ACAEngine::Driver::Subscriptions::Subscription
    @terminated = false
  end

  def terminate
    @terminated = true
    clear
  end

  def clear : Nil
    subs = @subscriptions
    @subscriptions = [] of ACAEngine::Driver::Subscriptions::Subscription
    subs.each do |subscription|
      @subscriber.unsubscribe(subscription)
    end
  end

  def unsubscribe(subscription : ACAEngine::Driver::Subscriptions::Subscription)
    @subscriptions.delete(subscription)
    @subscriber.unsubscribe(subscription)
  end

  def channel(name, &callback : (ACAEngine::Driver::Subscriptions::ChannelSubscription, String) -> Nil) : ACAEngine::Driver::Subscriptions::ChannelSubscription
    raise "subscription proxy terminated" if @terminated
    sub = @subscriber.channel(name, &callback)
    @subscriptions << sub
    sub
  end

  def subscribe(system_id, module_name, index, status, &callback : (ACAEngine::Driver::Subscriptions::IndirectSubscription, String) -> Nil) : ACAEngine::Driver::Subscriptions::IndirectSubscription
    raise "subscription proxy terminated" if @terminated
    sub = @subscriber.subscribe(system_id, module_name, index, status, &callback)
    @subscriptions << sub
    sub
  end

  def subscribe(module_id, status, &callback : (ACAEngine::Driver::Subscriptions::DirectSubscription, String) -> Nil) : ACAEngine::Driver::Subscriptions::DirectSubscription
    raise "subscription proxy terminated" if @terminated
    sub = @subscriber.subscribe(module_id, status, &callback)
    @subscriptions << sub
    sub
  end
end
