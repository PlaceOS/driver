require "json"
require "log"
require "tasker"

class PlaceOS::Driver::Queue
  def initialize(
    @logger : ::Log = ::Log.for(PlaceOS::Driver::Queue),
    &@connected_callback : Bool -> Nil
  )
    @queue = Array(Task).new

    # Queue controls
    @channel = Channel(Nil).new(1)
    @terminated = false
    @waiting = false
    @mutex = Mutex.new

    spawn(same_thread: true) { process! }
  end

  getter logger : ::Log
  getter current : Task? = nil
  getter previous : Task? = nil
  getter terminated : Bool
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
      @waiting = false
      @channel.send(nil)
    end
  rescue error
    @logger.warn(exception: error) { "changing queue state" }
  end

  def online : Bool
    @online == true
  end

  # removes all jobs currently in the queue
  def clear(abort_current = false)
    old_queue = @mutex.synchronize do
      # Ensure we have a reference to the latest version of the queue
      old = @queue
      # Create a new queue so tasks can be added as old tasks are cleared
      @queue = Array(Task).new
      old
    end

    # Abort any currently running tasks
    @current.try &.abort("queue cleared") if abort_current

    # Abort all the queued tasks
    old_queue.each(&.abort("queue cleared"))

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
      previous.try &.delay_required?

      # Perform tasks
      task = @mutex.synchronize { @queue.shift }
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
  rescue error
    logger.error(exception: error) { "unexpected exception processing queue" }
  ensure
    # The queue should always be running so we need to restart it
    spawn(same_thread: true) { process! } unless @terminated
  end

  protected def queue_task(priority, task)
    task.apparent_priority = priority
    name = task.name

    if @online
      @mutex.synchronize do
        @queue.push task
        @queue.sort! { |a, b| b.apparent_priority <=> a.apparent_priority }
        @queue.reject! { |t| t != task && t.name == name } if name
      end

      # buffered channel so this shouldn't block receive
      if @waiting
        @waiting = false
        @channel.send(nil)
      end
    elsif name
      @mutex.synchronize do
        @queue.push task
        @queue.sort! { |a, b| b.apparent_priority <=> a.apparent_priority }
        @queue.reject! { |t| t != task && t.name == name }
      end
    else
      spawn(same_thread: true) { task.abort("transport is currently offline") }
    end
    task
  end
end
