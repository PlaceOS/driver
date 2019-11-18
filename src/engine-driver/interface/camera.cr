require "./moveable"
require "./stoppable"

module ACAEngine::Driver::Interface; end

module ACAEngine::Driver::Interface::Camera
  include Interface::Stoppable
  include Interface::Moveable

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
  @zoom = 0

  @pan_range = 0..1
  @tilt_range = 0..1
  @zoom_range = 0..1

  # Most cameras support sending a move speed
  abstract def joystick(pan_speed : Int32, tilt_speed : Int32, index : Int32 | String = 1)

  # This a discrete level on most cameras
  abstract def zoom_to(position : Int32, auto_focus : Bool = true, index : Int32 | String = 1)

  # Natively supported on the device
  alias NativePreset = String

  # manual recall of a position
  alias DiscretePreset = NamedTuple(pan: Int32, tilt: Int32, zoom: Int32, focus: Int32?, iris: Int32?)

  # Most cameras support presets (either as a feature or via manual positioning)
  abstract def recall(position : String, index : Int32 | String = 1)
  abstract def save_position(name : String, index : Int32 | String = 1)

  enum TiltDirection
    Down
    Up
    Stop
  end

  def tilt(direction : TiltDirection, index : Int32 | String = 1)
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

  def pan(direction : PanDirection, index : Int32 | String = 1)
    case direction
    when PanDirection::Left
      move(MoveablePosition::Left, index)
    when PanDirection::Right
      move(MoveablePosition::Right, index)
    when PanDirection::Stop
      stop(index)
    end
  end

  enum ZoomDirection
    In
    Out
    Stop
  end

  @zoom_timer : ACAEngine::Driver::Proxy::Scheduler::TaskWrapper? = nil
  @zoom_speed : Int32 = 10

  # As zoom is typically discreet we manually implement the analogue version
  # Simple enough to overwrite this as required
  def zoom(direction : ZoomDirection, index : Int32 | String = 1)
    if zoom_timer = @zoom_timer
      zoom_timer.cancel(reason: "new request", terminate: true)
      @zoom_timer = nil
    end

    return if direction == ZoomDirection::Stop
    change = @zoom_range.begin <= @zoom_range.end ? @zoom_speed : -@zoom_speed
    change = direction == ZoomDirection::In ? change : -change

    @zoom_timer = scheduler.every(250.milliseconds, immediate: true) do
      zoom_to(@zoom + change, auto_focus: false)
    end
  end
end
