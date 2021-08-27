require "./zoomable"
require "./moveable"
require "./stoppable"

abstract class PlaceOS::Driver
  module Interface::Camera
    include Interface::Stoppable
    include Interface::Moveable
    include Interface::Zoomable

    # All cameras should expose limits:
    # ================================
    # pan_range, pan_speed
    # tilt_range, tilt_speed
    # zoom_range,
    # has_discrete_zoom = true / false
    #
    # Optional:
    # ========
    # focus_out, focus_in, has_discrete_focus
    # iris_open, iris_close, has_discrete_iris

    # Adjust these to appropriate values in on_load or on_connect
    @pan = 0
    @tilt = 0

    @pan_range = 0..1
    @tilt_range = 0..1

    # Most cameras support sending a move speed
    abstract def joystick(pan_speed : Int32, tilt_speed : Int32, index : Int32 | String = 0)

    # Natively supported on the device
    alias NativePreset = String

    # manual recall of a position
    alias DiscretePreset = NamedTuple(pan: Int32, tilt: Int32, zoom: Int32, focus: Int32?, iris: Int32?)

    # Most cameras support presets (either as a feature or via manual positioning)
    abstract def recall(position : String, index : Int32 | String = 0)
    abstract def save_position(name : String, index : Int32 | String = 0)

    enum TiltDirection
      Down
      Up
      Stop
    end

    def tilt(direction : TiltDirection, index : Int32 | String = 0)
      case direction
      when TiltDirection::Up
        move(MoveablePosition::Up, index)
      when TiltDirection::Down
        move(MoveablePosition::Down, index)
      when TiltDirection::Stop
        stop(index)
      end
    end

    enum PanDirection
      Left
      Right
      Stop
    end

    def pan(direction : PanDirection, index : Int32 | String = 0)
      case direction
      when PanDirection::Left
        move(MoveablePosition::Left, index)
      when PanDirection::Right
        move(MoveablePosition::Right, index)
      when PanDirection::Stop
        stop(index)
      end
    end
  end
end
