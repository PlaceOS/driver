require "./subscription"

class ACAEngine::Driver::Subscriptions::DirectSubscription < ACAEngine::Driver::Subscriptions::Subscription
  def initialize(@module_id : String, @status : String, &@callback : (DirectSubscription, String) ->)
    @storage = ACAEngine::Driver::Storage.new(@module_id)
  end

  def callback(logger : ::Logger, message : String) : Nil
    # Error handling is the responsibility of the callback
    # This is fine as this should only be used internally
    @callback.call(self, message)
  rescue e
    logger.error "error in subscription callback\n#{e.message}\n#{e.backtrace?.try &.join("\n")}"
  end

  getter :module_id, :status

  def subscribe_to : String?
    "#{@storage.hash_key}\x02#{@status}"
  end

  def current_value : String?
    @storage[@status]?
  end
end
