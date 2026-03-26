abstract class PlaceOS::Driver
  module Interface::StandbyImage
    abstract def set_background_image(url : String) : Nil
  end
end
