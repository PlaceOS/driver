abstract class PlaceOS::Driver
  module Interface::Zoomable
    @zoom = 0
    @zoom_range = 0..1

    # This a discrete level on most cameras
    abstract def zoom_to(position : Int32, auto_focus : Bool = true, index : Int32 | String = 0)

    enum ZoomDirection
      In
      Out
      Stop
    end

    @zoom_timer : PlaceOS::Driver::Proxy::Scheduler::TaskWrapper? = nil
    @zoom_speed : Int32 = 10

    # As zoom is typically discreet we manually implement the analogue version
    # Simple enough to overwrite this as required
    def zoom(direction : ZoomDirection, index : Int32 | String = 0)
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
end
