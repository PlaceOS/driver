require "json"
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
    ParseError     # 0
    BadRequest     # 1
    AccessDenied   # 2
    RequestFailed  # 3
    UnknownCommand # 4

    SystemNotFound    # 5
    ModuleNotFound    # 6
    UnexpectedFailure # 7

    def to_s
      super.underscore
    end
  end

  class Error < ::Exception
    getter error_code

    def initialize(@error_code : ErrorCode, message = "")
      super(message)
    end
  end

  def initialize(
    @sys_id : String,
    @module_name : String,
    @index : Int32,
    @security : Clearance = Clearance::Admin
  )
  end

  getter metadata : ACAEngine::Driver::DriverModel::Metadata? = nil
  getter module_id : String? = nil

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

  def function_visible?(function : String)
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
      {Clearance::Support, Clearance::Admin}.includes?(@security)
    when "administrator"
      @security == Clearance::Admin
    else
      false
    end
  end

  # TODO:: noop, requires etcd lookup
  def which_core? : URI?
    module_id = module_id?
    raise Error.new(ErrorCode::ModuleNotFound, "could not find module id") unless module_id

    URI.parse("https://core_1")
  end

  def exec(function, args : Array(JSON::Any)? = nil, named_args : Hash(String, JSON::Any)? = nil)
    metadata = metadata?
    raise Error.new(ErrorCode::ModuleNotFound, "could not find module") unless metadata
    raise Error.new(ErrorCode::BadRequest, "could not find function #{function}") unless function_present?(function)
    raise Error.new(ErrorCode::AccessDenied, "attempted to access privileged function #{function}") unless function_visible?(function)

    core_uri = which_core?

    # TODO:: build request
  end
end
