module PlaceOS::Driver::Interface; end

module PlaceOS::Driver::Interface::Locatable
  abstract def locate_user(email : String? = nil, username : String? = nil)
end
