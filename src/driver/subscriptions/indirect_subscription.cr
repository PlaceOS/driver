require "./subscription"

class PlaceOS::Driver::Subscriptions::IndirectSubscription < PlaceOS::Driver::Subscriptions::Subscription
  def initialize(@system_id : String, @module_name : String, @index : Int32, @status : String, &@callback : (IndirectSubscription, String) ->)
  end

  def callback(logger : ::Log, message : String) : Nil
    # Error handling is the responsibility of the callback
    # This is fine as this should only be used internally
    @callback.call(self, message)
  rescue e
    logger.error(exception: e) { "error in subscription callback" }
  end

  @storage : PlaceOS::Driver::Storage?
  @module_id : String?

  getter :system_id, :module_name, :index, :module_id, :status

  def subscribe_to : String?
    if get_module_id
      "#{@storage.not_nil!.hash_key}/#{@status}"
    end
  end

  def current_value : String?
    get_module_id
    if storage = @storage
      storage[@status]?
    end
  end

  def reset
    @storage = @module_id = nil
  end

  private def get_module_id
    module_id = @module_id
    return module_id if module_id

    lookup = PlaceOS::Driver::Storage.new(@system_id, "system")
    module_id = lookup["#{@module_name}/#{@index}"]?

    if module_id
      @module_id = module_id
      @storage = PlaceOS::Driver::Storage.new(module_id)
    end
  end
end
