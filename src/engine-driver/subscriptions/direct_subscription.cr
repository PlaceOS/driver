require "./subscription"

class EngineDriver::Subscriptions::DirectSubscription < EngineDriver::Subscriptions::Subscription
  def initialize(@module_id : String, status, &@callback)
    @status = status.to_s
    @storage = EngineDriver::Storage.new(@module_id)
  end

  @callback : (EngineDriver::Subscriptions::DirectSubscription, String) -> Nil

  getter :module_id, :status

  def subscribe_to
    "#{@storage.hash_key}\x02#{@status}"
  end

  def current_value
    @storage[@status]?
  end
end
