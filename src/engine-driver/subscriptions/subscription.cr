
abstract class EngineDriver::Subscriptions::Subscription
  def callback(message : String)
    @callback.call(self, message)
  end

  abstract def subscribe_to : String?
  abstract def current_value : String?
end
