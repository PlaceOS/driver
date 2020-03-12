require "./subscription"

class PlaceOS::Driver::Subscriptions::ChannelSubscription < PlaceOS::Driver::Subscriptions::Subscription
  def initialize(@channel : String, &@callback : (ChannelSubscription, String) ->)
  end

  def callback(logger : ::Logger, message : String) : Nil
    # Error handling is the responsibility of the callback
    # This is fine as this should only be used internally
    @callback.call(self, message)
  rescue e
    logger.error "error in subscription callback\n#{e.message}\n#{e.backtrace?.try &.join("\n")}"
  end

  getter :channel

  def subscribe_to : String?
    "placeos/#{@channel}"
  end

  def current_value : String?
    nil
  end
end
