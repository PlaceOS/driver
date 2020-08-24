require "json"
require "log"
require "priority-queue"
require "tasker"

class PlaceOS::Driver::Queue
  def initialize(@logger : ::Log = ::Log.for("driver.queue"), &@connected_callback : Bool -> Nil)
    @queue = Priority::Queue(Task).new

    # Queue controls
    @channel = Channel(Nil).new
    @terminated = false
    @waiting = false

    spawn(same_thread: true) { process! }
  end

  getter logger : ::Log
  getter current : Task? = nil
  getter previous : Task? = nil
  @online : Bool? = nil

  # for modifying defaults
  property priority : Int32 = 50
  property timeout : Time::Span = 5.seconds
  property retries : Int32 = 3
  property wait : Bool = true
  property delay : Time::Span? = nil
  property retry_bonus : Int32 = 20

  def online=(state : Bool)
    state_changed = state != @online
    @online = state
    spawn(same_thread: true) { @connected_callback.call(state) } if state_changed
    if @online && @waiting && @queue.size > 0
      spawn(same_thread: true) { @channel.send nil }
    end
  end

  def online : Bool
    @online == true
  end

  # removes all jobs currently in the queue
  def clear(abort_current = false)
    old_queue = @queue
    @queue = Priority::Queue(Task).new

    # Abort any currently running tasks
    if abort_current
      if current = @current
        current.abort("queue cleared")
      end
    end

    # Abort all the queued tasks
    size = old_queue.size
    (0...size).each do
      task = old_queue.pop.value
      task.abort("queue cleared")
    end

    self
  end

  # A helper method for setting the connected state, without effecting queue
  # processing. UDP device not responding, incorrect login etc
  def set_connected(state)
    @connected_callback.call(state)
  end

  def add(
    priority = @priority,
    timeout = @timeout,
    retries = @retries,
    wait = @wait,
    name = nil,
    delay = @delay,
    clear_queue = false,
    &callback : (Task) -> Nil
  )
    # Task returned so response_required! can be called as required
    task = Task.new(self, callback, priority, timeout, retries, wait, name.try &.to_s, delay, clear_queue)
    queue_task(priority, task)
  end

  def terminate
    @terminated = true
    @channel.close
  end

  private def process!
    loop do
      # Wait for a new task to be available
      if @online && @queue.size > 0
        break if @terminated
      else
        @waiting = true
        @channel.receive?
        @waiting = false

        break if @terminated

        # Prevent any race conditions
        # Could be multiple adds before receive returns
        next if !@online || @queue.size <= 0
      end

      # Check if the previous task should effect the current task
      if previous = @previous
        previous.delay_required?
      end

      # Perform tasks
      task = @queue.pop.value
      @current = task
      complete = task.execute!.__get

      # track delays etc
      @previous = @current
      @current = nil

      if complete
        # clear the queue as required
        clear if task.clear_queue
      else
        # re-queue the current task
        priority = task.priority + @retry_bonus
        queue_task(priority, task)
      end
    end
  end

  protected def queue_task(priority, task)
    if @online
      @queue.push priority, task
      # Spawn so the channel send occurs next tick
      spawn(same_thread: true) { @channel.send nil } if @waiting
    elsif task.name
      @queue.push priority, task
    else
      spawn(same_thread: true) { task.abort("transport is currently offline") }
    end
    task
  end
end
