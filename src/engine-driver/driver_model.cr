require "json"

class EngineDriver::DriverModel
  class ControlSystem
    JSON.mapping(
      id: String,
      name: String,
      email: String,
      capacity: Int32,
      features: String,
      bookable: Bool
    )
  end

  class Metadata
    def initialize(
      @functions = {} of String => Hash(String, Array(String)),
      @implements = [] of String
    )
    end

    JSON.mapping(
      functions: Hash(String, Hash(String, Array(String))),
      implements: Array(String)
    )
  end

  enum Role
    SSH
    RAW
    HTTP
    LOGIC
  end

  JSON.mapping(
    control_system: ControlSystem?,
    ip: String?,
    udp: Bool,
    port: Int32?,
    makebreak: Bool,
    uri: String?,
    settings: Hash(String, JSON::Any),
    role: Role
  )
end
