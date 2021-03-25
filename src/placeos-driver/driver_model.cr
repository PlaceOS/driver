require "json"

struct PlaceOS::Driver::DriverModel
  include JSON::Serializable

  struct ControlSystem
    include JSON::Serializable

    property id : String
    property name : String
    property email : String?
    property features : Array(String)?
    property bookable : Bool
    property display_name : String?
    property code : String?
    property type : String?
    property capacity : Int32
    property map_id : String?
  end

  struct Metadata
    include JSON::Serializable

    def initialize(
      @functions = {} of String => Hash(String, Array(JSON::Any)),
      @implements = [] of String,
      @requirements = {} of String => Array(String),
      @security = {} of String => Array(String)
    )
    end

    # Functions available on module, map of function name to args
    property functions : Hash(String, Hash(String, Array(JSON::Any)))
    # Interfaces implemented by module
    property implements : Array(String)
    # Module requirements, map of module name to required interfaces
    property requirements : Hash(String, Array(String))
    # Function access control, map of access level to function names
    property security : Hash(String, Array(String))
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

  {% if compare_versions(Crystal::VERSION, "1.0.0") < 0 %}
    @[JSON::Field(converter: Enum::ValueConverter(Role))]
    property role : Role
  {% else %}
    property role : Role
  {% end %}
end
