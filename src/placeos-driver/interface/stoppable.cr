abstract class PlaceOS::Driver
  # for a device that can be stopped
  module Interface::Stoppable
    abstract def stop(index : Int32 | String = 0, emergency : Bool = false)
  end
end
