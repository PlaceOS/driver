require "priority-queue"
require "tasker"
require "json"

class EngineDriver::Task
  DEFAULT_RESULT = "[null]"
  DEFAULT_BACKTR = [] of String

  def initialize(
    @queue : EngineDriver::Queue,
    @callback : Proc(Task, Nil),
    @priority : Int32,
    @timeout : Time::Span,
    @retries : Int32,
    @wait : Bool,
    @name : String?
  )
    @response_required = false
    @last_executed = 0_i64
    @channel = Channel(Nil).new

    @state = :unknown
    @payload = DEFAULT_RESULT
    @backtrace = DEFAULT_BACKTR
  end

  @timer : Tasker::Task?
  @processing : Proc(Bytes, Nil)?
  getter :last_executed, :state, :payload, :backtrace
  property :processing

  def result
    {result: @state, payload: @payload, backtrace: @backtrace}
  end

  # Are we intending to provide this result to a third party?
  def response_required!
    @response_required = true
    self
  end

  def execute!
    return self if @channel.closed?

    @callback.call(self)
    @last_executed = Time.now.to_unix_ms
    @wait ? start_timers : @channel.close
    self
  rescue e
    @state = :exception
    @payload = e.message || "error executing task"
    @backtrace = e.backtrace? || DEFAULT_BACKTR
    @channel.close
    self
  end

  def get(response_required = false)
    response_required! if response_required
    @channel.receive?
    result
  end

  def delay_required?
    # TODO:: Check if any delays need to be performed
  end

  # result should support conversion to JSON
  def success(result = nil)
    @state = :success

    if @response_required && result.responds_to?(:to_json)
      begin
        @payload = [result].to_json
      rescue
        # TODO:: log the error
      end
    end
    @channel.close
    self
  end

  # A partial response was received
  def reset_timers
    # start if there should be a timer and we are still waiting for a response
    start_timers if @wait && !@channel.closed?
  end

  # Possible failure or device busy.
  def retry
    return unless @wait && !@channel.closed?

    # TODO:: log the retry

    @retries -= 1
    if @retries >= 0
      stop_timers
      delay_required?
      execute!
    else
      abort("timeout")
    end
  end

  # Failed except we don't want to retry
  def abort(reason = nil)
    stop_timers
    @state = :abort
    @payload = reason.to_s if reason
    @channel.close
    self
  end

  private def start_timers
    stop_timers if @timer
    @timer = Tasker.instance.in(@timeout) do
      @timer = nil
      self.retry
    end
  end

  private def stop_timers
    @timer.try &.cancel
    @timer = nil
  end
end
