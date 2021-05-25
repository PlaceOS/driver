require "tasker"
require "set"

require "../driver_manager"

class PlaceOS::Driver::Proxy::Scheduler
  enum Action
    Add
    Remove
  end

  class TaskWrapper
    def initialize(@task : Tasker::Task, @callback : (TaskWrapper, Action) -> Bool)
    end

    delegate created, get, last_scheduled, next_epoch, next_scheduled, trigger, trigger_count, to: @task

    def cancel(reason = "Task canceled", terminate = false)
      @callback.call(self, Action::Remove) unless terminate
      @task.cancel reason
    end

    def resume
      @task.resume unless @callback.call(self, Action::Add)
    end
  end

  getter logger : ::Log

  def initialize(@logger = ::Log.for("driver.scheduler"))
    @schedules = Set(TaskWrapper).new
    @terminated = false
    @callback = Proc(TaskWrapper, Action, Bool).new do |wrapped, action|
      case action
      in .add?    then @schedules << wrapped
      in .remove? then @schedules.delete(wrapped)
      end
      @terminated
    end
  end

  delegate size, to: @schedules

  def at(time, immediate = false, &block : -> _)
    raise "schedule proxy terminated" if @terminated
    spawn(same_thread: true) { run_now(block) } if immediate
    wrapped = nil
    task = Tasker.at(time) do
      @schedules.delete(wrapped.not_nil!)
      run_now(block)
    end
    wrap = wrapped = TaskWrapper.new(task, @callback)
    @schedules << wrap
    wrap
  end

  def in(time, immediate = false, &block : -> _)
    raise "schedule proxy terminated" if @terminated
    spawn(same_thread: true) { run_now(block) } if immediate
    wrapped = nil
    task = Tasker.in(time) do
      @schedules.delete(wrapped.not_nil!)
      run_now(block)
    end
    wrap = wrapped = TaskWrapper.new(task, @callback)
    @schedules << wrap
    wrap
  end

  def every(time, immediate = false, &block : -> _)
    raise "schedule proxy terminated" if @terminated
    spawn(same_thread: true) { run_now(block) } if immediate
    task = Tasker.every(time) { run_now(block) }
    wrap = TaskWrapper.new(task, @callback)
    @schedules << wrap
    wrap
  end

  def cron(string, timezone : Time::Location = Time::Location.local, immediate = false, &block : -> _)
    raise "schedule proxy terminated" if @terminated
    spawn(same_thread: true) { run_now(block) } if immediate
    task = Tasker.cron(string, timezone) { run_now(block) }
    wrap = TaskWrapper.new(task, @callback)
    @schedules << wrap
    wrap
  end

  def terminate
    @terminated = true
    clear
  end

  def clear
    schedules = @schedules
    @schedules = Set(TaskWrapper).new
    schedules.each &.cancel(terminate: @terminated)
  end

  private def run_now(block)
    block.call
  rescue error
    logger.error(exception: error) { "in scheduled task on #{DriverManager.driver_class}" }
    raise error
  end
end
