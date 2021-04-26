abstract class PlaceOS::Driver; end

module PlaceOS::Driver::Interface::ElectricalRelay
  abstract def relay(state : Bool, index : Int32 = 0, **options)

  def pulse(period : Float64 = 1.0, index : Int32 = 0, times : Int32 = 1, initial_state = false)
    queue(name: "pulse_#{index}") do |task|
      # higher pririty so these commands run next once added to the queue
      priority = queue.priority + 25
      period = pause_for.seconds

      times.times do
        relay(!initial_state, index, delay: period, priority: priority)
        relay(initial_state, index, delay: period, priority: priority)
      end
      task.success
    end
  end
end
