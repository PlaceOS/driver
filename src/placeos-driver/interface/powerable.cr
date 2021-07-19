abstract class PlaceOS::Driver
  # Compatible drivers will expose a status variable:
  # ```
  # self[:power] # `true` / `false`
  # ```
  # The power state function allows one to sepecify a preferred level of off if
  # supported by the device
  module Interface::Powerable
    abstract def power(state : Bool)

    enum PowerState
      On
      Off
      FullOff
    end

    # override this to implement `PowerState::FullOff` if it is available for the device
    def power_state(state : PowerState)
      power case state
      in .on?              then true
      in .off?, .full_off? then false
      end
    end
  end
end
