require "tasker"

require "../driver_manager"

class PlaceOS::Driver::Proxy::Scheduler
  class TaskWrapper
    def initialize(@task : Tasker::Task, @schedules : Array(TaskWrapper))
      @terminated = false
    end

    PROXY = %w(created trigger_count last_scheduled next_scheduled next_epoch trigger get)
    {% for method in PROXY %}
      def {{method.id}}
        @task.{{method.id}}
      end
    {% end %}

    def cancel(reason = "Task canceled", terminate = false)
      @terminated = true if terminate
      @schedules.delete(self)
      @task.cancel reason
    end

    def resume
      raise "schedule proxy terminated" if @terminated
      @schedules << self unless @schedules.includes?(self)
      @task.resume
    end
  end

  def initialize(@logger = ::Logger.new(STDOUT))
    @scheduler = Tasker.instance
    @schedules = [] of TaskWrapper
    @terminated = false
  end

  @scheduler : Tasker

  def size
    @schedules.size
  end

  def at(time, immediate = false, &block : -> _)
    raise "schedule proxy terminated" if @terminated
    spawn(same_thread: true) { run_now(block) } if immediate
    wrapped = nil
    task = @scheduler.at(time) do
      @schedules.delete(wrapped.not_nil!)
      run_now(block)
    end
    wrap = wrapped = TaskWrapper.new(task, @schedules)
    @schedules << wrap
    wrap
  end

  def in(time, immediate = false, &block : -> _)
    raise "schedule proxy terminated" if @terminated
    spawn(same_thread: true) { run_now(block) } if immediate
    wrapped = nil
    task = @scheduler.in(time) do
      @schedules.delete(wrapped.not_nil!)
      run_now(block)
    end
    wrap = wrapped = TaskWrapper.new(task, @schedules)
    @schedules << wrap
    wrap
  end

  def every(time, immediate = false, &block : -> _)
    raise "schedule proxy terminated" if @terminated
    spawn(same_thread: true) { run_now(block) } if immediate
    task = @scheduler.every(time) { run_now(block) }
    wrap = TaskWrapper.new(task, @schedules)
    @schedules << wrap
    wrap
  end

  def cron(string, immediate = false, &block : -> _)
    raise "schedule proxy terminated" if @terminated
    spawn(same_thread: true) { run_now(block) } if immediate
    task = @scheduler.every(time) { run_now(block) }
    wrap = TaskWrapper.new(task, @schedules)
    @schedules << wrap
    wrap
  end

  def terminate
    @terminated = true
    clear
  end

  def clear
    schedules = @schedules
    @schedules = [] of TaskWrapper
    schedules.each &.cancel(terminate: @terminated)
  end

  private def run_now(block)
    block.call
  rescue error
    @logger.error "in scheduled task on #{DriverManager.driver_class}\n#{error.inspect_with_backtrace}"
    raise error
  end
end
