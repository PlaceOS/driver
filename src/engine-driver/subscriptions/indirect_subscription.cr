require "./subscription"

class EngineDriver::Subscriptions::IndirectSubscription < EngineDriver::Subscriptions::Subscription
  def initialize(@system_id : String, @module_name : String, @index : Int32, @status : String, &@callback)
  end

  @storage : EngineDriver::Storage?
  @module_id : String?
  @callback : (EngineDriver::Subscriptions::IndirectSubscription, String) -> Nil

  getter :system_id, :module_name, :index, :module_id, :status

  def subscribe_to
    if get_module_id
      "#{@storage.not_nil!.hash_key}\x02#{@status}"
    end
  end

  def current_value
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

    module_id = EngineDriver::Storage.get("lookup\x02#{@system_id}\x02#{@module_name}\x02#{@index}")
    if module_id
      @module_id = module_id
      @storage = EngineDriver::Storage.new(module_id)
    end
  end
end
