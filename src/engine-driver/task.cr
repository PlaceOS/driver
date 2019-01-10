require "priority-queue"
require "tasker"
require "json"

class EngineDriver::Task
  DEFAULT_RESULT = "null"
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

    @logger = @queue.logger

    @state = :unknown
    @payload = DEFAULT_RESULT
    @backtrace = DEFAULT_BACKTR
    @error_class = nil
  end

  @logger : ::Logger
  @timer : Tasker::Task?
  @processing : Proc(Bytes, Nil)?
  @error_class : String?
  getter :last_executed, :state, :payload, :backtrace, :error_class, :logger
  property :processing

  def result
    {result: @state, payload: @payload, backtrace: @backtrace, error: @error_class}
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
    @logger.error "error executing task #{@name}\n#{e.message}\n#{e.backtrace?.try &.join("\n")}"
    @state = :exception
    @payload = e.message || "error executing task"
    @backtrace = e.backtrace? || DEFAULT_BACKTR
    @error_class = e.class.to_s
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

    if @response_required
      begin
        @payload = result.try_to_json("null")
      rescue e
        @logger.warn "unable to convert result to JSON\n#{e.message}\n#{e.backtrace?.try &.join("\n")}"
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
    return if @wait == false || @channel.closed?

    @logger.info do
      if @name
        "retrying command #{@name.inspect} due to timeout"
      else
        "retrying command due to timeout"
      end
    end

    @retries -= 1
    if @retries >= 0
      stop_timers
      delay_required?
      execute!
    else
      abort("retries failed")
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
