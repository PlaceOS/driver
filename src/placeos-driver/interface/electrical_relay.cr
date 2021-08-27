abstract class PlaceOS::Driver
  module Interface::ElectricalRelay
    # `**options` here should be passed to the `task` to allow for different priorities
    abstract def relay(state : Bool, index : Int32 = 0, **options)

    def pulse(period : Int32 = 1000, index : Int32 = 0, times : Int32 = 1, initial_state : Bool = false)
      queue(name: "pulse_#{index}") do |task|
        # higher pririty so these commands run next once added to the queue
        priority = queue.priority + 25
        pause_for = period.milliseconds

        times.times do
          relay(!initial_state, index, delay: pause_for, priority: priority)
          relay(initial_state, index, delay: pause_for, priority: priority)
        end
        task.success
      end
    end
  end
end
