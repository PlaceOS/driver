require "json"

abstract class PlaceOS::Driver
  module Interface::GuestBuildingAccess
    # use inheritance to provide additional details as required to revoke access
    abstract class AccessDetails
      include JSON::Serializable
      include JSON::Serializable::Unmapped

      property user_id : String? = nil
      property permission_id : String? = nil
      property card_number : Int64? = nil
      property card_facility : Int64? = nil
    end

    # a function for granting guests access to a building
    # should return a payload that can be encoded into a QR code
    # the response is expected to be hexstring
    abstract def grant_guest_access(name : String, email : String, starting : Int64, ending : Int64) : AccessDetails

    # revoke access to a building
    abstract def revoke_guest_access(details : JSON::Any)

    # return true if we can grant guest access
    abstract def guest_access_configured? : Bool
  end
end
