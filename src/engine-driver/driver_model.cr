require "json"

class EngineDriver::DriverModel
  include JSON::Serializable

  class ControlSystem
    include JSON::Serializable

    property id : String
    property name : String
    property email : String
    property capacity : Int32
    property features : String
    property bookable : Bool
  end

  class Metadata
    include JSON::Serializable

    def initialize(
      @functions = {} of String => Hash(String, Array(String)),
      @implements = [] of String
    )
    end

    property functions : Hash(String, Hash(String, Array(String)))
    property implements : Array(String)
  end

  enum Role
    SSH
    RAW
    HTTP
    LOGIC
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
