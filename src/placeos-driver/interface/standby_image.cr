abstract class PlaceOS::Driver
  module Interface::StandbyImage
    abstract def set_background_image(url : String, output_index : Int32? = nil) : Nil
  end
end
