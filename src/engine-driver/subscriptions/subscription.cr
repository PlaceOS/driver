abstract class EngineDriver::Subscriptions::Subscription
  abstract def callback(message : String) : Nil
  abstract def subscribe_to : String?
  abstract def current_value : String?

  def system_id
    nil
  end
end
