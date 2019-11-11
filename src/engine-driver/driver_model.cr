require "json"

struct ACAEngine::Driver::DriverModel
  include JSON::Serializable

  struct ControlSystem
    include JSON::Serializable

    property id : String
    property name : String
    property email : String?
    property capacity : Int32
    property features : String?
    property bookable : Bool
  end

  struct Metadata
    include JSON::Serializable

    def initialize(
      @functions = {} of String => Hash(String, Array(String)),
      @implements = [] of String,
      @requirements = {} of String => Array(String),
      @security = {} of String => Array(String)
    )
    end

    # Functions available on module, map of function name to args
    property functions : Hash(String, Hash(String, Array(String)))
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
    LOGIC
    WEBSOCKET
  end

  property control_system : ControlSystem?
  property ip : String?
  property udp : Bool
  property tls : Bool
  property port : Int32?
  property makebreak : Bool
  property uri : String?
  property settings : Hash(String, JSON::Any)
  property role : Role
end
