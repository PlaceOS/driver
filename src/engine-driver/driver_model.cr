require "json"

class EngineDriver::DriverModel
  enum Role
    SSH
    RAW
    HTTP
    LOGIC
  end

  JSON.mapping(
    ip: String?,
    udp: Bool,
    port: Int32?,
    makebreak: Bool,
    uri: String?,
    settings: Hash(String, JSON::Any),
    role: Role
  )
end
