abstract class PlaceOS::Driver
  module Interface::Stoppable
    abstract def stop(index : Int32 | String = 0, emergency : Bool = false)
  end
end
