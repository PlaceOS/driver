require "redis_service_manager"
require "json"
require "placeos-core-client"
require "uuid"

require "../storage"
require "../driver_model"
require "../subscriptions"
require "./subscriptions"
require "./system"

# This is a helper class for integrating internal components that communicate
# directly to core but are external to core, such as the API or Triggers
#
# Metadata is cached for the lifetime of the object, so you should not cache
# this object for extended periods. It should be considered disposable with a
# time delta that is considered reasonable in the face of change.
# i.e eventual consistency
module PlaceOS::Driver::Proxy
  class RemoteDriver
    CORE_NAMESPACE = "core"

    class_getter default_discovery : Clustering::Discovery do
      manager = RedisServiceManager.new(
        service: CORE_NAMESPACE,
        redis: Driver::RedisStorage.shared_redis_client,
        lock: Driver::RedisStorage.redis_lock
      )
      Clustering::Discovery.new(manager)
    end

    enum Clearance
      User
      Support
      Admin
    end

    enum ErrorCode
      # JSON parsing error
      ParseError = 0
      # Pre-requisite does not exist (i.e no function)
      BadRequest = 1
      # The current user does not have permissions
      AccessDenied = 2
      # The request was sent and error occured in core / the module
      RequestFailed = 3
      # Not one of bind, unbind, exec, debug, ignore
      UnknownCommand = 4
      # System ID was not found in the database
      SystemNotFound = 5
      # Module does not exist in this system
      ModuleNotFound = 6
      # Some other transient failure like database unavailable
      UnexpectedFailure = 7

      def to_s
        super.underscore
      end
    end

    class Error < ::Exception
      getter error_code, system_id, module_name, index, response_code
      property remote_backtrace : Array(String)?

      def initialize(
        @error_code : ErrorCode,
        message : String? = nil,
        @system_id : String = "",
        @module_name : String = "",
        @index : Int32 = 1,
        @remote_backtrace : Array(String)? = nil,
        @response_code : Int32 = 500,
      )
        super(message)
      end
    end

    def initialize(
      @sys_id : String,
      @module_name : String,
      @index : Int32,
      @discovery : Clustering::Discovery = RemoteDriver.default_discovery,
      @user_id : String? = nil,
      &@edge_id : String -> String
    )
      @error_details = {@sys_id, @module_name, @index}
    end

    def initialize(
      @module_id : String,
      @sys_id : String,
      @module_name : String,
      @index : Int32 = 1,
      @discovery : Clustering::Discovery = RemoteDriver.default_discovery,
      @user_id : String? = nil,
      &@edge_id : String -> String
    )
      @error_details = {@sys_id, @module_name, 1}
    end

    getter metadata : DriverModel::Metadata? = nil
    getter module_id : String? = nil
    getter :module_name, :index, :sys_id

    @status : RedisStorage? = nil

    # a callback for looking up the edge id so we can route requests correctly
    # passes the module id and expects the edge id to be returned
    @edge_id : String -> String

    def status : RedisStorage
      redis_store = @status
      return redis_store if redis_store

      module_id = module_id?
      raise Error.new(ErrorCode::ModuleNotFound, "could not find module id", *@error_details) unless module_id
      @status = RedisStorage.new(module_id)
    end

    def module_id? : String?
      return @module_id if @module_id
      @module_id = Proxy::System.module_id?(@sys_id, @module_name, @index)
    end

    def metadata? : DriverModel::Metadata?
      return @metadata if @metadata
      if module_id = module_id?
        # TODO: Pass storage's redis client
        @metadata = Proxy::System.driver_metadata?(module_id)
      end
    end

    def function_present?(function : String) : Bool
      if metadata = metadata?
        metadata.interface.keys.includes?(function)
      else
        false
      end
    end

    def function_visible?(security : Clearance, function : String)
      metadata = metadata?
      return false unless metadata

      # Find the access control level containing the function, if any.
      access_control = metadata.security.find do |_, functions|
        functions.includes? function
      end

      # No access control on the function... general access.
      return true unless access_control

      level, _ = access_control

      # Check user's privilege against the function's privilege.
      case level
      when "support"
        {Clearance::Support, Clearance::Admin}.includes?(security)
      when "administrator"
        security == Clearance::Admin
      else
        false
      end
    end

    # Use consistent hashing to determine the location of the module
    #
    def which_core : URI
      module_id = module_id?
      raise Error.new(ErrorCode::ModuleNotFound, "could not find module id", *@error_details) unless module_id

      which_core(module_id)
    end

    private EDGE_HINT = "-edge"

    # Use consistent hashing to determine location of a resource
    #
    def which_core(hash_id : String) : URI
      node = if hash_id.ends_with? EDGE_HINT
               @discovery[@edge_id.call(hash_id)]?
             else
               @discovery[hash_id]?
             end
      raise Error.new(ErrorCode::UnexpectedFailure, "No registered core instances", *@error_details) unless node
      node
    end

    # Executes a request against the appropriate core and returns the JSON result
    #
    def exec(
      security : Clearance,
      function : String,
      args = nil,
      named_args = nil,
      request_id : String? = nil,
      user_id : String? = @user_id,
    ) : {String, Int32}
      metadata = metadata?
      raise Error.new(ErrorCode::ModuleNotFound, "could not find module", *@error_details) unless metadata
      raise Error.new(ErrorCode::BadRequest, "could not find function #{function}", *@error_details) unless function_present?(function)
      raise Error.new(ErrorCode::AccessDenied, "attempted to access privileged function #{function}", *@error_details) unless function_visible?(security, function)

      module_id = module_id?
      raise Error.new(ErrorCode::ModuleNotFound, "could not find module id", *@error_details) unless module_id

      exec_args = args || named_args
      Core::Client.client(which_core, request_id) do |client|
        begin
          client.execute(module_id, function, exec_args, user_id: user_id)
        rescue error : Core::DriverRaisedError
          raise Error.new(ErrorCode::RequestFailed, error.message, *@error_details, error.remote_backtrace, error.response_code)
        rescue error : Core::UnexpectedFailureError | Core::APIResponseError | IO::Error
          raise Error.new(ErrorCode::UnexpectedFailure, error.message, *@error_details)
        end
      end
    end

    def [](status)
      value = status[status]
      JSON.parse(value)
    end

    def []?(status)
      value = status[status]?
      JSON.parse(value) if value
    end

    def status(klass, key)
      klass.from_json(status[key.to_s])
    end

    def status?(klass, key)
      value = status[key.to_s]?
      klass.from_json(value) if value
    end

    # Returns a websocket that sends debugging logging to the remote
    # Each message consists of an array `[0, "message"]`
    # Easiest way to parse is: `Tuple(Logger::Severity, String).from_json(%([0, "test"]))`
    #
    def debug(request_id : String? = nil)
      module_id = module_id?
      raise Error.new(ErrorCode::ModuleNotFound, "could not find module id", *@error_details) unless module_id
      Core::Client.client(which_core, request_id) do |client|
        client.debug(module_id)
      end
    end

    # All subscriptions to external drivers should be indirect as the driver might
    # be swapped into a completely different system - whilst we've looked up the id
    # of this instance of a driver, it's expected that this object is short lived
    def subscribe(subscriptions : Proxy::Subscriptions, status, &callback : (Driver::Subscriptions::IndirectSubscription, String) -> Nil) : Driver::Subscriptions::IndirectSubscription
      if @module_id
        subscriptions.subscribe(@module_id, status, &callback)
      else
        subscriptions.subscribe(@sys_id, @module_name, @index, status, &callback)
      end
    end

    # Extract module name and module id from string
    # e.g. "Display_3" => {"Display", 3}
    # "Display" => {"Display", 1}
    # "My_Display" => {"My_Display", 1}
    #
    def self.get_parts(module_id : String | Symbol) : {String, Int32}
      module_id = module_id.to_s if module_id.is_a?(Symbol)
      mod_name, match, index = module_id.rpartition('_')
      if match.empty?
        {module_id, 1}
      else
        idx = index.to_i?
        idx ? {mod_name, idx} : {module_id, 1}
      end
    end
  end
end
