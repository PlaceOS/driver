require "./subscription"

class EngineDriver::Subscriptions::DirectSubscription < EngineDriver::Subscriptions::Subscription
  def initialize(@module_id : String, @status : String, &@callback : (DirectSubscription, String) ->)
    @storage = EngineDriver::Storage.new(@module_id)
  end

  def callback(logger : ::Logger, message : String)
    # Error handling is the responsibility of the callback
    # This is fine as this should only be used internally
    @callback.call(self, message)
  rescue e
    logger.error "error in subscription callback\n#{e.message}\n#{e.backtrace?.try &.join("\n")}"
  end

  getter :module_id, :status

  def subscribe_to
    "#{@storage.hash_key}\x02#{@status}"
  end

  def current_value
    @storage[@status]?
  end
end
