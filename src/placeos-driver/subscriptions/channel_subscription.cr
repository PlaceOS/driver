require "./subscription"
require "path"

class PlaceOS::Driver::Subscriptions::ChannelSubscription < PlaceOS::Driver::Subscriptions::Subscription
  def initialize(@channel : String, &@callback : (ChannelSubscription, String) ->)
  end

  def callback(logger : ::Log, message : String) : Nil
    # Error handling is the responsibility of the callback
    # This is fine as this should only be used internally
    @callback.call(self, message)
  rescue e
    logger.error(exception: e) { "error in subscription callback" }
  end

  getter :channel

  def subscribe_to : String?
    Path["placeos/"].join(@channel).to_s
  end

  def current_value : String?
    nil
  end
end
