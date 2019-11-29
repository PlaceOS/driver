require "json"
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
class ACAEngine::Driver::Proxy::RemoteDriver
  enum Clearance
    User
    Support
    Admin
  end

  @[Flags]
  enum ErrorCode
    # JSON parsing error
    ParseError     # 0
    # Pre-requisite does not exist (i.e no function)
    BadRequest     # 1
    # The current user does not have permissions
    AccessDenied   # 2
    # The request was sent and error occured in core / the module
    RequestFailed  # 3
    # Not one of bind, unbind, exec, debug, ignore
    UnknownCommand # 4
    # System ID was not found in the database
    SystemNotFound    # 5
    # Module does not exist in this system
    ModuleNotFound    # 6
    # Some other transient failure like database unavailable
    UnexpectedFailure # 7

    def to_s
      super.underscore
    end
  end

  class Error < ::Exception
    getter error_code, system_id, module_name, index
    property remote_backtrace : Array(String)?

    def initialize(
      @error_code : ErrorCode,
      message : String = "",
      @system_id : String = "",
      @module_name : String = "",
      @index : Int32 = 1,
      @remote_backtrace : Array(String)? = nil
    )
      super(message)
    end
  end

  def initialize(
    @sys_id : String,
    @module_name : String,
    @index : Int32
  )
    @error_details = {@sys_id, @module_name, @index}
  end

  getter metadata : ACAEngine::Driver::DriverModel::Metadata? = nil
  getter module_id : String? = nil
  getter :module_name, :index

  @status : ACAEngine::Driver::Storage? = nil

  def status : ACAEngine::Driver::Storage
    redis_store = @status
    return redis_store if redis_store

    module_id = module_id?
    raise Error.new(ErrorCode::ModuleNotFound, "could not find module id", *@error_details) unless module_id
    @status = ACAEngine::Driver::Storage.new(module_id)
  end

  def module_id? : String?
    return @module_id if @module_id
    @module_id = Proxy::System.module_id?(@sys_id, @module_name, @index)
  end

  def metadata? : ACAEngine::Driver::DriverModel::Metadata?
    return @metadata if @metadata
    if module_id = module_id?
      @metadata = Proxy::System.driver_metadata?(module_id)
    end
  end

  def function_present?(function : String) : Bool
    if metadata = metadata?
      metadata.functions.keys.includes?(function)
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

  # TODO:: noop, requires etcd lookup
  def which_core? : URI?
    module_id = module_id?
    raise Error.new(ErrorCode::ModuleNotFound, "could not find module id", *@error_details) unless module_id

    URI.parse("https://core_1")
  end

  def which_core?(hash_id : String) : URI?
    URI.parse("https://core_1")
  end

  # Executes a request against the appropriate core and returns the JSON result
  #
  def exec(security : Clearance, function : String, args : Array(JSON::Any)? = nil, named_args : Hash(String, JSON::Any)? = nil) : String
    metadata = metadata?
    raise Error.new(ErrorCode::ModuleNotFound, "could not find module", *@error_details) unless metadata
    raise Error.new(ErrorCode::BadRequest, "could not find function #{function}", *@error_details) unless function_present?(function)
    raise Error.new(ErrorCode::AccessDenied, "attempted to access privileged function #{function}", *@error_details) unless function_visible?(security, function)

    module_id = module_id?
    raise Error.new(ErrorCode::ModuleNotFound, "could not find module id", *@error_details) unless module_id

    core_uri = which_core?(module_id)

    # build request
    core_uri.path = "/api/core/v1/command/#{module_id}/execute"
    response = HTTP::Client.post(core_uri, body: {
      "__exec__" => function,
      function => args || named_args
    }.to_json)

    case response.status_code
    when 200
      # exec was successful, json string returned
      response.body
    when 203
      # exec sent to module and it raised an error
      info = NamedTuple(
        message: String,
        backtrace: Array(String)?
      ).from_json(response.body)

      raise Error.new(ErrorCode::RequestFailed, "module raised: #{info[:message]}", *@error_details, info[:backtrace])
    else
      # some other failure 3
      raise Error.new(ErrorCode::UnexpectedFailure, "unexpected response code #{response.status_code}", *@error_details)
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

  # All subscriptions to external drivers should be indirect as the driver might
  # be swapped into a completely different system - whilst we've looked up the id
  # of this instance of a driver, it's expected that this object is short lived
  def subscribe(subscriptions : Proxy::Subscriptions, status, &callback : (ACAEngine::Driver::Subscriptions::IndirectSubscription, String) -> Nil) : ACAEngine::Driver::Subscriptions::IndirectSubscription
    subscriptions.subscribe(@sys_id, @module_name, @index, status, &callback)
  end
end
