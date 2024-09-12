require "json"

abstract class PlaceOS::Driver
  module Interface::GuestBuildingAccess
    # use inheritance to provide additional details as required to revoke access
    abstract class AccessDetails
      include JSON::Serializable
      include JSON::Serializable::Unmapped

      property card_hex : String
    end

    # temp until finally is resolved
    protected def __revoke_guest_access__(details : JSON::Any)
    end

    macro included
      macro finally
        \{% begin %}
          alias SubKlassAccessDetails = \{{ parse_type("AccessDetails").resolve.subclasses.first }}
        \{% end %}

        protected def __revoke_guest_access__(details : JSON::Any)
          revoke_access SubKlassAccessDetails.from_json(details.to_json)
        end
      end
    end

    # revoke access to a building
    def revoke_guest_access(details : JSON::Any) : Nil
      __revoke_guest_access__ details
    end

    # a function for granting guests access to a building
    # should return a payload that can be encoded into a QR code
    # the response is expected to be hexstring
    abstract def grant_guest_access(name : String, email : String, starting : Int64, ending : Int64) : AccessDetails

    # where details is an instance of your AccessDetails subclass
    protected abstract def revoke_access(details)
  end
end
