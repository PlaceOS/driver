require "./subscription"

class EngineDriver::Subscriptions::ChannelSubscription < EngineDriver::Subscriptions::Subscription
  def initialize(@channel : String, &@callback : (EngineDriver::Subscriptions::ChannelSubscription, String) ->)
  end

  def callback(message : String)
    # TODO:: catch and log errors here!
    @callback.call(self, message)
  end

  getter :channel

  def subscribe_to
    "engine\x02#{@channel}"
  end

  def current_value
    nil
  end
end
