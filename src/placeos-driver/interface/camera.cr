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

    # Most cameras support sending a move speed, the interface should expect a percentage
    abstract def joystick(pan_speed : Float64, tilt_speed : Float64, index : Int32 | String = 0)

    # Most cameras support presets (either as a feature or via manual positioning)
    abstract def recall(position : String, index : Int32 | String = 0)
    abstract def save_position(name : String, index : Int32 | String = 0)

    enum TiltDirection
      Down
      Up
      Stop

      def move : MoveablePosition?
        case self
        in .up?   then MoveablePosition::Up
        in .down? then MoveablePosition::Down
        in .stop? then nil
        end
      end
    end

    def tilt(direction : TiltDirection, index : Int32 | String = 0)
      move_in_direction(direction, index)
    end

    enum PanDirection
      Left
      Right
      Stop

      def move : MoveablePosition?
        case self
        in .left?  then MoveablePosition::Left
        in .right? then MoveablePosition::Right
        in .stop?  then nil
        end
      end
    end

    def pan(direction : PanDirection, index : Int32 | String = 0)
      move_in_direction(direction, index)
    end

    private def move_in_direction(direction : PanDirection | TiltDirection, index)
      if position = direction.move
        move(position, index)
      else
        stop(index)
      end
    end
  end
end
