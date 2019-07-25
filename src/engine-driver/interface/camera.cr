module EngineDriver::Interface; end

module EngineDriver::Interface::Camera
  # All cameras should expose limits:
  # ================================
  # pan_left, pan_right, pan_stop,
  # tilt_down, tilt_up, tilt_stop,
  # zoom_max, zoom_min
  # has_discrete_zoom = true / false
  #
  # Optional:
  # ========
  # focus_out, focus_in, has_discrete_focus
  # iris_open, iris_close, has_discrete_iris

  # Adjust these to appropriate values in on_load
  @pan_left : Int32 = 0
  @pan_stop : Int32 = 50
  @pan_right : Int32 = 100

  @tilt_down : Int32 = 0
  @tilt_stop : Int32 = 50
  @tilt_up : Int32 = 100

  @zoom_min : Int32 = 0
  @zoom_max : Int32 = 100
  @zoom_position : Int32 = 0
  @has_discrete_zoom : Bool = true

  # Default speed values, offset from stopped integer
  @pan_speed : Int32 = 20
  @tilt_speed : Int32 = 20
  @zoom_speed : Int32 = 5

  # Most cameras support sending a move speed
  abstract def joystick(pan_speed : Int32, tilt_speed : Int32)

  # This a discrete level on most cameras
  abstract def set_zoom(position : Int32, auto_focus : Bool = true)

  # Natively supported on the device
  alias NativePreset = String

  # manual recall of a position
  alias DiscretePreset = NamedTuple({pan: Int32, tilt: Int32, zoom: Int32, focus: Int32?, iris: Int32?})

  # Most cameras support presets (either as a feature or via manual positioning)
  abstract def recall(position : String)
  abstract def save_position(name : String)

  enum TiltDirection
    Down
    Up
    Stop
  end

  def tilt(direction : TiltDirection)
    offset = @tilt_down < @tilt_stop ? @tilt_speed : -@tilt_speed

    speed = case direction
            when TiltDirection::Down
              -offset
            when TiltDirection::Up
              offset
            when TiltDirection::Stop
              @tilt_stop
            else
              raise "unsupported direction"
            end

    joystick @pan_stop, speed
  end

  enum PanDirection
    Left
    Right
    Stop
  end

  def pan(direction : PanDirection)
    offset = @pan_left < @pan_stop ? @pan_speed : -@pan_speed

    speed = case direction
            when PanDirection::Left
              -offset
            when PanDirection::Right
              offset
            when PanDirection::Stop
              @tilt_stop
            else
              raise "unsupported direction"
            end

    joystick speed, @tilt_stop
  end

  enum ZoomDirection
    In
    Out
    Stop
  end

  @zoom_timer : EngineDriver::Proxy::Scheduler::TaskWrapper? = nil

  # As zoom is typically discreet we manually implement the analogue version
  # Simple enough to overwrite this as required
  def zoom(direction : ZoomDirection) : Nil
    if zoom_timer = @zoom_timer
      zoom_timer.cancel(reason: "new request", terminate: true)
      @zoom_timer = nil
    end

    return if direction == ZoomDirection::Stop
    change = @zoom_min <= @zoom_max ? @zoom_speed : -@zoom_speed
    change = direction == ZoomDirection::In ? change : -change

    @zoom_timer = scheduler.every(250.milliseconds, immediate: true) do
      set_zoom(@zoom_position + change, auto_focus: false)
    end
  end
end
