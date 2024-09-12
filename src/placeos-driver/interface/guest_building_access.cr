require "json"

abstract class PlaceOS::Driver
  module Interface::GuestBuildingAccess
    # use inheritance to provide additional details as required to revoke access
    abstract class AccessDetails
      include JSON::Serializable
      include JSON::Serializable::Unmapped

      property card_hex : String
    end

    macro included
      {% begin %}
        alias SubKlassAccessDetails = {{ parse_type("::AccessDetails").resolve.subclasses.first }}
      {% end %}
      
      # revoke access to a building
      def revoke_guest_access(details : SubKlassAccessDetails) : Nil
        revoke_access details
      end
    end

    # a function for granting guests access to a building
    # should return a payload that can be encoded into a QR code
    # the response is expected to be hexstring
    abstract def grant_guest_access(name : String, email : String, starting : Int64, ending : Int64) : AccessDetails

    # where details is an instance of your AccessDetails subclass
    protected abstract def revoke_access(details)
  end
end
