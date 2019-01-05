abstract class EngineDriver::Subscriptions::Subscription
  def callback(message : String)
    # TODO:: catch and log errors here!
    @callback.call(self, message)
  end

  abstract def subscribe_to : String?
  abstract def current_value : String?

  def system_id
    nil
  end
end
