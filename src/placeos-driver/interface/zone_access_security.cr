require "json"

abstract class PlaceOS::Driver
  module Interface::ZoneAccessSecurity
    # using an email address, lookup the security system id for a user
    abstract def card_holder_id_lookup(email : String) : String | Int64 | Nil

    abstract struct CardHolderDetails
      include JSON::Serializable

      getter id : String | Int64
      getter name : String
      getter email : String?
    end

    # given a card holder id, lookup the details of the card holder
    abstract def card_holder_lookup(id : String | Int64) : CardHolderDetails

    # using a name, lookup the access zone id
    abstract def zone_access_id_lookup(name : String, exact_match : Bool = true) : String | Int64 | Nil

    abstract struct ZoneDetails
      include JSON::Serializable

      getter id : String | Int64
      getter name : String
      getter description : String?
    end

    # given an access zone id, lookup the details of the zone
    abstract def zone_access_lookup(id : String | Int64) : ZoneDetails

    # return the id that represents the access permission (truthy indicates access)
    abstract def zone_access_member?(zone_id : String | Int64, card_holder_id : String | Int64) : String | Int64 | Nil

    # add a member to the zone
    abstract def zone_access_add_member(zone_id : String | Int64, card_holder_id : String | Int64, from_unix : Int64? = nil, until_unix : Int64? = nil)

    # remove a member from the zone
    abstract def zone_access_remove_member(zone_id : String | Int64, card_holder_id : String | Int64)
  end
end
