require "json"

abstract class PlaceOS::Driver
  module Interface::GuestBuildingAccess
    # use inheritance to provide additional details as required to revoke access
    abstract class AccessDetails
      include JSON::Serializable
      include JSON::Serializable::Unmapped

      property card_hex : String
    end

    # a function for granting guests access to a building
    # should return a payload that can be encoded into a QR code
    # the response is expected to be hexstring
    abstract def grant_guest_access(email : String, from : Int64, until : Int64) : AccessDetails

    # revoke access to a building
    def revoke_guest_access(access : AccessDetails) : Nil
      access_json = access.to_json
      details = {{ parse_type("::PlaceOS::Driver::Interface::GuestBuildingAccess::AccessDetails").resolve.subclasses.first }}.from_json(access_json)
      revoke_access details
    end

    # where details is an instance of your AccessDetails subclass
    abstract protected def revoke_access(details)
  end
end
