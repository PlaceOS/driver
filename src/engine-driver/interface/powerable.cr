module EngineDriver::Interface; end

# Compatible drivers will expose a status variable:
# self[:power] = PowerState::On
# which is exposed as the string "On"
module EngineDriver::Interface::Powerable
  abstract def power(state : Bool)

  enum PowerState
    On
    Off
    FullOff
  end

  def power_state(state : PowerState)
    case state
    when PowerState::On
      power true
    when PowerState::Off, PowerState::FullOff
      power false
    end
  end
end
