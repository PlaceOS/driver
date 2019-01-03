
class EngineDriver::Subscriptions::ChannelSubscription < Subscription
  def initialize(@channel : String, &@callback)
  end

  @callback : (EngineDriver::Subscriptions::ChannelSubscription, String) -> Nil

  getter :channel

  def subscribe_to
    "engine\x02#{@channel}"
  end

  def current_value
    nil
  end
end
