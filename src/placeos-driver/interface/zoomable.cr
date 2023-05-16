abstract class PlaceOS::Driver
  # Implements the direct `zoom_to` function
  #
  # if the device supports continuous zoom then you should overwrite the included `zoom` function
  module Interface::Zoomable
    @zoom : Float64 = 0.0

    # This a discrete level on most cameras
    abstract def zoom_to(position : Float64, auto_focus : Bool = true, index : Int32 | String = 0)

    enum ZoomDirection
      In
      Out
      Stop
    end

    @zoom_timer : PlaceOS::Driver::Proxy::Scheduler::TaskWrapper? = nil
    @zoom_step : Float64 = 5.0

    # As zoom is typically discreet we manually implement the analogue version
    # Simple enough to overwrite this as required
    def zoom(direction : ZoomDirection, index : Int32 | String = 0)
      if zoom_timer = @zoom_timer
        zoom_timer.cancel(reason: "new request", terminate: true)
        @zoom_timer = nil
      end

      return if direction == ZoomDirection::Stop
      change = direction == ZoomDirection::In ? @zoom_step : -@zoom_step

      @zoom_timer = schedule.every(250.milliseconds, immediate: true) do
        zoom_to(@zoom + change, auto_focus: false)
      end
    end
  end
end
