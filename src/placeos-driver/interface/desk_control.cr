abstract class PlaceOS::Driver
  # Common desk control interface
  module Interface::DeskControl
    # desk height is in mm
    abstract def set_desk_height(
      desk_key : String,
      desk_height : Int32
    )

    # return nil on unknown height
    abstract def get_desk_height(desk_key : String) : Int32?

    # desk_power on / off / nil == auto
    abstract def set_desk_power(
      desk_key : String,
      desk_power : Bool?
    )

    abstract def get_desk_power(desk_key : String) : Bool?
  end
end
