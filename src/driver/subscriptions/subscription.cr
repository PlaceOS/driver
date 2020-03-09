require "../storage"

abstract class PlaceOS::Driver::Subscriptions::Subscription
  abstract def callback(logger : ::Logger, message : String) : Nil
  abstract def subscribe_to : String?
  abstract def current_value : String?

  def system_id
    nil
  end
end
