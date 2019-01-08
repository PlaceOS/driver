require "./subscription"

class EngineDriver::Subscriptions::ChannelSubscription < EngineDriver::Subscriptions::Subscription
  def initialize(@channel : String, &@callback : (ChannelSubscription, String) ->)
  end

  def callback(logger : ::Logger, message : String)
    # Error handling is the responsibility of the callback
    # This is fine as this should only be used internally
    @callback.call(self, message)
  rescue e
    logger.error "error in subscription callback\n#{e.message}\n#{e.backtrace?.try &.join("\n")}"
  end

  getter :channel

  def subscribe_to
    "engine\x02#{@channel}"
  end

  def current_value
    nil
  end
end
