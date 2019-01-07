require "./subscription"

class EngineDriver::Subscriptions::DirectSubscription < EngineDriver::Subscriptions::Subscription
  def initialize(@module_id : String, @status : String, &@callback : (EngineDriver::Subscriptions::DirectSubscription, String) ->)
    @storage = EngineDriver::Storage.new(@module_id)
  end

  def callback(message : String)
    # TODO:: catch and log errors here!
    @callback.call(self, message)
  end

  getter :module_id, :status

  def subscribe_to
    "#{@storage.hash_key}\x02#{@status}"
  end

  def current_value
    @storage[@status]?
  end
end
