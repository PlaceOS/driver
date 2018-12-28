require "priority-queue"
require "tasker"
require "json"

class EngineDriver::Queue
  def initialize
    @queue = Priority::Queue(Task).new
    @priority = 50
    @timeout = 5.seconds
    @retries = 3
    @wait = true
    @current = nil
    @channel = Channel(Nil).new
    @waiting = 0
    @terminated = false
  end

  @current : Task?
  @previous : Task?
  @timeout : Time::Span
  getter :current, :waiting

  def add(
    priority = @priority,
    timeout = @timeout,
    retries = @retries,
    wait = @wait,
    name = nil,
    &callback : (Task) -> Nil
  )
    task = Task.new(self, callback, priority, timeout, retries, wait, name)
    @queue.push priority, task
    spawn { @channel.send nil }

    # Task returned so response_required! can be called as required
    task
  end

  def terminate
    @terminated = true
    @channel.close
  end

  def process!
    loop do
      # Wait for a new task to be available
      @waiting += 1
      @channel.receive?
      @waiting -= 1

      break if @terminated

      # Check if the previous task should effect the current task
      if previous = @previous
        previous.delay_required?
      end

      # Perform tasks
      task = @queue.pop.value
      @current = task
      task.execute!.get

      # Task complete
      @previous = @current
      @current = nil
    end
  end
end
