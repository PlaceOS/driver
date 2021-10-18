abstract class PlaceOS::Driver
  module Interface::InputSelection(Input)
    # Switches all outputs to the requested input
    # Special case `switch_to 0` should mute all the outputs, if supported
    abstract def switch_to(input : Input)
  end

  module Interface::Switchable(Input, Output)
    include Interface::InputSelection(Input)

    enum SwitchLayer
      All
      Audio
      Video
      Data
      Data2
    end

    abstract def switch(map : Hash(Input, Array(Output)), layer : SwitchLayer? = nil)
  end
end
