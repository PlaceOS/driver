require "../subscriptions"

class PlaceOS::Driver::Proxy::Subscriptions
  def initialize(@subscriber : PlaceOS::Driver::Subscriptions = PlaceOS::Driver::Subscriptions.new)
    @subscriptions = [] of PlaceOS::Driver::Subscriptions::Subscription
    @terminated = false
  end

  def terminate
    @terminated = true
    clear
  end

  def clear : Nil
    subs = @subscriptions
    @subscriptions = [] of PlaceOS::Driver::Subscriptions::Subscription
    subs.each do |subscription|
      @subscriber.unsubscribe(subscription)
    end
  end

  def unsubscribe(subscription : PlaceOS::Driver::Subscriptions::Subscription)
    @subscriptions.delete(subscription)
    @subscriber.unsubscribe(subscription)
  end

  def channel(name, &callback : (PlaceOS::Driver::Subscriptions::ChannelSubscription, String) -> Nil) : PlaceOS::Driver::Subscriptions::ChannelSubscription
    raise "subscription proxy terminated" if @terminated
    sub = @subscriber.channel(name, &callback)
    @subscriptions << sub
    sub
  end

  def subscribe(system_id, module_name, index, status, &callback : (PlaceOS::Driver::Subscriptions::IndirectSubscription, String) -> Nil) : PlaceOS::Driver::Subscriptions::IndirectSubscription
    raise "subscription proxy terminated" if @terminated
    sub = @subscriber.subscribe(system_id, module_name, index, status, &callback)
    @subscriptions << sub
    sub
  end

  def subscribe(module_id, status, &callback : (PlaceOS::Driver::Subscriptions::DirectSubscription, String) -> Nil) : PlaceOS::Driver::Subscriptions::DirectSubscription
    raise "subscription proxy terminated" if @terminated
    sub = @subscriber.subscribe(module_id, status, &callback)
    @subscriptions << sub
    sub
  end
end
