require "json"

struct PlaceOS::Driver::DriverModel
  include JSON::Serializable

  struct ControlSystem
    include JSON::Serializable

    property id : String
    property name : String
    property description : String?
    property email : String?
    property features : Array(String)?
    property bookable : Bool
    property display_name : String?
    property code : String?
    property type : String?
    property capacity : Int32
    property map_id : String?
    property timezone : String?
    property support_url : String?
    property zones : Array(String)
    property images : Array(String)?
  end

  struct Metadata
    include JSON::Serializable

    # :nodoc:
    def initialize(
      @interface : Hash(String, Hash(String, JSON::Any))? = nil,
      @implements : Array(String) = [] of String,
      @requirements : Hash(String, Array(String)) = {} of String => Array(String),
      @security : Hash(String, Array(String)) = {} of String => Array(String),
      @settings = {type: "object", properties: {} of String => JSON::Any, required: [] of String},
      @notes = nil,
    )
      @interface ||= {} of String => Hash(String, JSON::Any)
      @functions = nil
    end

    # :nodoc:
    @[Deprecated("Use `#interface` instead of functions")]
    def initialize(
      @functions : Hash(String, Hash(String, Array(JSON::Any)))? = nil,
      @implements = [] of String,
      @requirements = {} of String => Array(String),
      @security = {} of String => Array(String),
      @settings = {type: "object", properties: {} of String => JSON::Any, required: [] of String},
    )
      @functions ||= {} of String => Hash(String, Array(JSON::Any))
      @interface = nil
    end

    # Functions available on module, map of function name to args
    property interface : Hash(String, Hash(String, JSON::Any))?
    property functions : Hash(String, Hash(String, Array(JSON::Any)))?

    # Interfaces implemented by module
    property! implements : Array(String)

    # Module requirements, map of module name to required interfaces
    property! requirements : Hash(String, Array(String))

    # Function access control, map of access level to function names
    property! security : Hash(String, Array(String))

    # JSON Schema derived from the settings used in the driver
    property settings : NamedTuple(type: String, properties: Hash(String, JSON::Any)?, required: Array(String)?)?

    # Notes that might be relevant to a LLM
    property notes : String? = nil

    # a minimal interface for informing Large Language Models
    def llm_interface
      @settings = nil
      @implements = nil
      @requirements = nil
      iface = interface
      @security.try &.each do |_level, functions|
        # remove support and administrator level functions from the descriptions
        # as we don't want LLMs accessing these
        functions.each do |function|
          iface.delete(function)
        end
      end
      @security = nil
      @functions = nil
      self
    end

    def arity(function_name : String | Symbol)
      interface[function_name.to_s].size
    end

    # Note:: the use of both these functions is temporary
    @[Deprecated("Use `#interface` instead")]
    def functions : Hash(String, Hash(String, Array(JSON::Any)))
      funcs = @functions
      return funcs if funcs

      funcs = {} of String => Hash(String, Array(JSON::Any))
      @interface.not_nil!.each do |func_name, arguments|
        arg_hash = {} of String => Array(JSON::Any)
        arguments.each do |arg_name, schema|
          values = [schema]
          default = schema["default"]?
          values << default if default

          arg_hash[arg_name] = values
        end
        funcs[func_name] = arg_hash
      end

      @functions = funcs
    end

    def interface : Hash(String, Hash(String, JSON::Any))
      iface = @interface
      return iface if iface

      Log.warn { "Deprecated metadata in use. A driver update is required" }

      funcs = {} of String => Hash(String, JSON::Any)
      @functions.not_nil!.each do |func_name, arguments|
        arg_hash = {} of String => JSON::Any
        arguments.each do |arg_name, values|
          default = values[1]?
          if default
            arg_hash[arg_name] = JSON::Any.new({"default" => default})
          else
            arg_hash[arg_name] = JSON::Any.new({} of String => JSON::Any)
          end
        end
        funcs[func_name] = arg_hash
      end

      @interface = funcs
    end
  end

  enum Role
    SSH
    RAW
    HTTP
    WEBSOCKET
    LOGIC     = 99
  end

  property control_system : ControlSystem?
  property ip : String?
  property udp : Bool
  property tls : Bool
  property port : Int32?
  property makebreak : Bool
  property uri : String?
  property settings : Hash(String, JSON::Any)
  property notes : String?

  @[JSON::Field(converter: Enum::ValueConverter(PlaceOS::Driver::DriverModel::Role))]
  property role : Role
end
