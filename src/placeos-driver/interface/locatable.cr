module PlaceOS::Driver::Interface; end

module PlaceOS::Driver::Interface::Locatable
  abstract def locate_user(identifier : String)
end
