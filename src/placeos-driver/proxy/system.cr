require "json"

require "../driver_model"
require "./remote_driver"

class PlaceOS::Driver::Proxy::System
  def initialize(
    @model : DriverModel::ControlSystem,
    @reply_id : String,
    @logger : ::Log = ::Log.for("driver.proxy.system"),
    @subscriptions : Proxy::Subscriptions = Proxy::Subscriptions.new
  )
    @system_id = @model.id
    @system = PlaceOS::Driver::RedisStorage.new(@system_id, "system")
  end

  @system_id : String

  getter logger : ::Log

  def [](module_name)
    get_driver(*get_parts(module_name))
  end

  def get(module_name)
    get_driver(*get_parts(module_name))
  end

  def get(module_name, index)
    get_driver(module_name, index)
  end

  # Retrieve module metadata from redis
  #
  def self.module_id?(system_id, module_name, index) : String?
    PlaceOS::Driver::RedisStorage.new(system_id, "system")["#{module_name}/#{index}"]?
  end

  # Retrieve module metadata from redis
  #
  def self.driver_metadata?(system_id, module_name, index) : PlaceOS::Driver::DriverModel::Metadata?
    # Pull module_id from System redis
    module_id = self.module_id?(system_id, module_name, index)

    module_id.try(&->self.driver_metadata?(String))
  end

  # Retrieve module metadata from redis, bypassing module_id lookup
  #
  def self.driver_metadata?(module_id) : PlaceOS::Driver::DriverModel::Metadata?
    RedisStorage
      .get("interface/#{module_id}")
      .try(&->DriverModel::Metadata.from_json(String))
  end

  private def get_driver(module_name, index) : PlaceOS::Driver::Proxy::Driver
    module_name = module_name.to_s
    index = index.to_i

    module_id = @system["#{module_name}/#{index}"]?
    metadata = get_metadata(module_id)
    module_id ||= "driver index unavailable"

    Proxy::Driver.new(@reply_id, module_name, index, module_id, self, metadata)
  end

  def all(module_name) : PlaceOS::Driver::Proxy::Drivers
    module_name = module_name.to_s
    drivers = [] of Proxy::Driver

    @system.keys.each do |key|
      parts = key.split("/")
      mod_name = parts[0]
      index = parts[1]

      if mod_name == module_name
        module_id = @system[key]
        metadata = get_metadata(module_id)
        drivers << Proxy::Driver.new(@reply_id, module_name, index.to_i, module_id, self, metadata)
      end
    end

    PlaceOS::Driver::Proxy::Drivers.new(drivers)
  end

  private def get_metadata(module_id : String?) : DriverModel::Metadata
    metadata_json = RedisStorage.get("interface/#{module_id}") if module_id.presence
    if metadata_json && !metadata_json.empty?
      DriverModel::Metadata.from_json metadata_json
    else
      # return a hollow proxy - we don't want to error
      # code can execute against a non-existance driver
      DriverModel::Metadata.new
    end
  end

  # grabs all modules implementing(Powerable) for example
  def implementing(interface) : PlaceOS::Driver::Proxy::Drivers
    interface = interface.to_s
    drivers = [] of Proxy::Driver

    @system.keys.each do |key|
      parts = key.split("/")
      mod_name = parts[0]
      index = parts[1]

      module_id = @system[key]
      metadata = RedisStorage.get("interface/#{module_id}")
      if module_id && metadata
        data = DriverModel::Metadata.from_json metadata
        next unless data.implements.includes?(interface) || data.functions[interface]?
        drivers << Proxy::Driver.new(@reply_id, mod_name, index.to_i, module_id, self, data)
      end
    end

    PlaceOS::Driver::Proxy::Drivers.new(drivers)
  end

  # coordination to occur on placeos core
  def load_complete(&callback : (PlaceOS::Driver::Subscriptions::ChannelSubscription, String) -> Nil)
    subscription = @subscriptions.channel("cluster/cluster_version", &callback)

    # NOTE:: we assume the cluster is ready on load.
    # All drivers should handle this cleanly
    spawn(same_thread: true) do
      begin
        callback.call(subscription, "ready")
      rescue error
        logger.error(exception: error) { "error in subscription callback" }
      end
    end

    subscription
  end

  # Manages subscribing to all the non-local subscriptions
  def subscribe(module_name, index, status, &callback : (PlaceOS::Driver::Subscriptions::IndirectSubscription, String) -> Nil) : PlaceOS::Driver::Subscriptions::IndirectSubscription
    @subscriptions.subscribe(@system_id, module_name, index, status, &callback)
  end

  def subscribe(module_name, status, &callback : (PlaceOS::Driver::Subscriptions::IndirectSubscription, String) -> Nil) : PlaceOS::Driver::Subscriptions::IndirectSubscription
    module_name, index = get_parts(module_name)
    @subscriptions.subscribe(@system_id, module_name, index, status, &callback)
  end

  def config
    @model
  end

  # Checks for the existence of a particular module
  def exists?(module_name, index = nil) : Bool
    module_name, index = get_parts(module_name) unless index
    !@system["#{module_name}/#{index}"]?.nil?
  end

  # Returns a list of all the module names in the system
  def modules
    @system.keys.map { |key| key.split("/")[0] }.uniq
  end

  # Grabs the number of a particular device type
  def count(module_name)
    module_name = module_name.to_s
    @system.keys.map { |key| key.split("/")[0] }.count { |key| key == module_name }
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
    RemoteDriver.get_parts(module_id)
  end
end
