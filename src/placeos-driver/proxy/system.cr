require "json"

require "../driver_model"
require "./remote_driver"

struct PlaceOS::Driver::Proxy::System
  # Local system available to logic driver
  def initialize(
    model : DriverModel::ControlSystem,
    @reply_id : String,
    @logger : ::Log = ::Log.for(PlaceOS::Driver::Proxy::System),
    @subscriptions : Proxy::Subscriptions = Proxy::Subscriptions.new,
  )
    @config = model
    @system_id = model.id
    @system = PlaceOS::Driver::RedisStorage.new(@system_id, "system")
  end

  # Remote system (lazily loaded config)
  def initialize(
    @system_id : String,
    @reply_id : String,
    @logger : ::Log = ::Log.for(PlaceOS::Driver::Proxy::System),
    @subscriptions : Proxy::Subscriptions = Proxy::Subscriptions.new,
  )
    @system = PlaceOS::Driver::RedisStorage.new(@system_id, "system")
  end

  @system : PlaceOS::Driver::RedisStorage
  @system_id : String
  @subscriptions : Proxy::Subscriptions
  @reply_id : String

  getter logger : ::Log

  getter config : DriverModel::ControlSystem do
    # Request the remote systems model
    response = PlaceOS::Driver::Protocol.instance.expect_response(@system_id, @reply_id, :sys).receive
    raise response.build_error if response.error
    DriverModel::ControlSystem.from_json response.payload.not_nil!
  end

  delegate bookable, capacity, email, features, name, display_name, to: config
  delegate description, code, type, map_id, timezone, support_url, zones, to: config

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

  def all(module_name, *, implementing) : PlaceOS::Driver::Proxy::Drivers
    module_name = module_name.to_s
    interface = implementing.to_s
    drivers = [] of Proxy::Driver

    @system.keys.each do |key|
      parts = key.split("/")
      mod_name = parts[0]
      next unless mod_name == module_name
      index = parts[1]

      module_id = @system[key]
      metadata = get_metadata(module_id)
      next unless metadata.implements.includes?(interface) || metadata.interface[interface]?
      drivers << Proxy::Driver.new(@reply_id, mod_name, index.to_i, module_id, self, metadata)
    end

    PlaceOS::Driver::Proxy::Drivers.new(drivers)
  end

  private def get_metadata(module_id : String?) : DriverModel::Metadata
    metadata = self.class.driver_metadata?(module_id) if module_id.presence

    # return a hollow proxy in case a driver isn't running
    # or still loading etc. we don't want to error
    metadata || DriverModel::Metadata.new
  rescue error
    logger.error(exception: error) { "failed to parse metadata for module: #{module_id}" }
    DriverModel::Metadata.new
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
      metadata = get_metadata(module_id)
      next unless metadata.implements.includes?(interface) || metadata.interface[interface]?
      drivers << Proxy::Driver.new(@reply_id, mod_name, index.to_i, module_id, self, metadata)
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

  # Checks for the existence of a particular module
  def exists?(module_name, index = nil) : Bool
    module_name, index = get_parts(module_name) unless index
    !@system["#{module_name}/#{index}"]?.nil?
  end

  # Returns a list of all the module names in the system
  def modules
    module_keys.uniq!
  end

  # Grabs the number of a particular device type
  def count(module_name)
    module_name = module_name.to_s
    module_keys.count(&.==(module_name))
  end

  def id
    @system_id
  end

  private def module_keys
    @system.keys.compact_map(&.split('/').first?)
  end

  private def get_parts(module_id)
    RemoteDriver.get_parts(module_id)
  end
end
