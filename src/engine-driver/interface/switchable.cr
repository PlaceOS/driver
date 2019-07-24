module EngineDriver::Interface; end

module EngineDriver::Interface::InputSelection
  # Switches all outputs to the requested input
  # Special case `switch_to 0` should mute all the outputs, if supported
  abstract def switch_to(input : Int32 | String)
end

module EngineDriver::Interface::Switchable
  include EngineDriver::Interface::InputSelection

  # { layer => { input => [output1, output2] } }
  alias SelectiveSwitch = Hash(String, Hash(Int32 | String, Array(Int32 | String)))

  # {input => [output1, output2]}
  alias FullSwitch = Hash(Int32 | String, Array(Int32 | String))

  enum SwitchLayer
    Audio
    Video
    Data
    Data2
  end

  abstract def switch(map : FullSwitch | SelectiveSwitch)
end
