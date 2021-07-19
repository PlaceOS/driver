require "../exception"

abstract class PlaceOS::Driver; end

class PlaceOS::Driver::Protocol; end

require "../driver_model"

module PlaceOS
  class Driver::Protocol::Request
    include JSON::Serializable

    enum Command
      Start
      Stop
      Update
      Terminate
      Exec
      Debug
      Ignore
      Info
      Result
      Exited

      # Fetch a ControlSystem for a module
      Sys

      # Notify of settings update
      Setting

      # Redis commands
      Hset
      Set
      Clear
    end

    def initialize(
      @id,
      @cmd : Command,
      @payload = nil,
      @error = nil,
      @backtrace = nil,
      @seq = nil,
      @reply = nil,
      @user_id = nil
    )
    end

    property id : String
    property cmd : Command

    # Security context
    property user_id : String?

    # Used to track request and responses
    property seq : UInt64?

    # For driver to driver comms to route the request back to the originating module
    property reply : String?

    property payload : String?
    property error : String?
    property backtrace : Array(String)?

    def set_error(error)
      self.payload = error.message
      self.error = error.class.to_s
      self.backtrace = error.backtrace?
      self
    end

    def build_error
      Driver::RemoteException.new(self.payload, self.error, self.backtrace || [] of String)
    end

    # Not part of the JSON payload, so we don't need to re-parse a request
    @[JSON::Field(ignore: true)]
    property driver_model : ::PlaceOS::Driver::DriverModel? = nil
  end
end
