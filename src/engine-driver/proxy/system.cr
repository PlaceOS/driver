require "json"

class EngineDriver::Proxy::System
  def initialize(
    @model : DriverModel::ControlSystem,
    @logger : ::Logger = ::Logger.new(STDOUT),
    @subscriptions : Proxy::Subscriptions = Proxy::Subscriptions.new
  )
    @system_id = @model.id
    @system = EngineDriver::Storage.new(@system_id, "system")
    @redis = EngineDriver::Storage.redis_pool
  end

  @system_id : String
  getter :logger

  def [](module_name)
    get_driver(*get_parts(module_name))
  end

  def get(module_name)
    get_driver(*get_parts(module_name))
  end

  def get(module_name, index)
    get_driver(module_name, index)
  end

  private def get_driver(module_name, index) : EngineDriver::Proxy::Driver
    module_name = module_name.to_s
    index = index.to_i

    module_id = @system["#{module_name}\x02#{index}"]?
    metadata = @redis.get("interface\x02#{module_id}") if module_id
    metadata = if module_id && metadata
                 EngineDriver::DriverModel::Metadata.from_json metadata
               else
                 # return a hollow proxy - we don't want to error
                 # code can execute against a non-existance driver
                 EngineDriver::DriverModel::Metadata.new
               end

    module_id ||= "driver index unavailable"

    EngineDriver::Proxy::Driver.new(module_name, index, module_id, self, metadata)
  end

  # TODO:: driver proxy
  def all(module_name)
    module_name = module_name.to_s
    modules = [] of String
    @system.each do |key, value|
      modules << value if key.split("\x02")[0] == module_name
    end

    # TODO:: requests proxy
  end

  # coordination to occur on engine core
  def load_complete(&callback : (EngineDriver::Subscriptions::ChannelSubscription, String) -> Nil)
    subscription = @subscriptions.channel("engine_load_complete", &callback)

    spawn do
      ready = @redis.get("engine_cluster_state") == "ready"
      if ready
        begin
          callback.call(subscription, "ready")
        rescue error
          @logger.error "error in subscription callback\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
        end
      end
    end

    subscription
  end

  # Manages subscribing to all the non-local subscriptions
  def subscribe(module_name, index, status = nil, &callback : (EngineDriver::Subscriptions::IndirectSubscription, String) -> Nil) : EngineDriver::Subscriptions::IndirectSubscription
    if status.nil?
      status = index
      module_name, index = get_parts(module_name)
    end
    @subscriptions.subscribe(@system_id, module_name, index, status, &callback)
  end

  def config
    @model
  end

  # Checks for the existence of a particular module
  def exists?(module_name, index = nil) : Bool
    module_name, index = get_parts(module_name) unless index
    !@system["#{module_name}\x02#{index}"]?.nil?
  end

  # Returns a list of all the module names in the system
  def modules
    @system.keys.map { |key| key.split("\x02")[0] }.uniq
  end

  # Grabs the number of a particular device type
  def count(module_name)
    module_name = module_name.to_s
    @system.keys.map { |key| key.split("\x02")[0] }.reject { |key| key != module_name }.size
  end

  def name
    @model.name
  end

  def email
    @model.email
  end

  def capacity
    @model.capacity
  end

  def features
    @model.features
  end

  def bookable
    @model.bookable
  end

  def id
    @system_id
  end

  private def get_parts(module_id)
    module_name, match, index = module_id.to_s.rpartition('_')
    if match.empty?
      {module_id, 1}
    else
      {module_name, index.to_i}
    end
  end
end
