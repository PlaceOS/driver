abstract class PlaceOS::Driver
  module Interface::DoorSecurity
    class Door
      include JSON::Serializable

      getter door_id : String
      getter description : String?

      def initialize(@door_id, @description = nil)
      end
    end

    abstract def door_list : Array(Door)

    # true for success, false for failed, nil for not supported
    abstract def unlock(door_id : String) : Bool?

    enum Action
      Granted
      Denied
      Tamper
      RequestToExit # REX
    end

    # drivers are expected to emit door state events on
    # channel security/event/door
    class DoorEvent
      include JSON::Serializable

      getter module_id : String
      getter security_system : String

      getter door_id : String
      getter timestamp : Int64
      getter action : Action
      getter card_id : String?
      getter user_name : String?
      getter user_email : String?

      def initialize(
        @module_id,
        @security_system,
        @door_id,
        @action,
        @card_id = nil,
        @user_name = nil,
        @user_email = nil,
        @timestamp = Time.utc.to_unix
      )
      end
    end
  end
end
