module PlaceOS::Driver::Interface; end

module PlaceOS::Driver::Interface::Stoppable
  abstract def stop(index : Int32 | String = 0, emergency : Bool = false)
end
