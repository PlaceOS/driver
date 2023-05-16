abstract class PlaceOS::Driver
  # a driver or service that can provide location information for people
  module Interface::Locatable
    # array of devices and their x, y coordinates, that are associated with this user
    abstract def locate_user(email : String? = nil, username : String? = nil)

    # return an array of MAC address strings
    # lowercase with no seperation characters abcdeffd1234 etc
    abstract def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)

    alias OwnershipMAC = NamedTuple(
      location: String,
      assigned_to: String,
      mac_address: String,
    )

    # return `nil` or `{"location": "wireless", "assigned_to": "bob123", "mac_address": "abcd"}`
    abstract def check_ownership_of(mac_address : String) : OwnershipMAC?

    # array of devices and their x, y coordinates
    abstract def device_locations(zone_id : String, location : String? = nil)
  end
end
