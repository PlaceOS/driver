require "tasker"
require "json"

class PlaceOS::Driver::Task
  DEFAULT_RESULT = "null"
  DEFAULT_BACKTR = [] of String

  def initialize(
    @queue : PlaceOS::Driver::Queue,
    @callback : Proc(Task, Nil),
    @priority : Int32,
    @timeout : Time::Span,
    @retries : Int32,
    @wait : Bool,
    @name : String?,
    @delay : Time::Span?,
    @clear_queue : Bool = false
  )
    @response_required = false
    @last_executed = 0_i64
    @channel = Channel(Nil).new
    # Was the process retried?
    @complete = Channel(Bool).new(1)

    @state = @wait ? :unknown : :success
    @payload = DEFAULT_RESULT
    @backtrace = DEFAULT_BACKTR
    @error_class = nil
  end

  @timer : Tasker::Task?
  @processing : Proc(Bytes, Task, Nil)?
  @error_class : String?
  getter last_executed, state, payload, backtrace, error_class
  getter name, delay, wait
  property processing, retries, priority, clear_queue
  property apparent_priority : Int32 = 0

  # Use the Queue's custom logger
  delegate logger, to: @queue

  # Drivers can monkey patch task if the request is required to process the response
  # @request_payload : Bytes?
  # property :request_payload

  # Are we intending to provide this result to a third party?
  def response_required!
    @response_required = true
    self
  end

  def execute!
    return self if @channel.closed?

    @callback.call(self)
    @last_executed = Time.utc.to_unix_ms
    if @wait
      start_timers
    else
      @channel.close unless @channel.closed?
      if !@complete.closed?
        @complete.send true
        @complete.close
      end
    end
    self
  rescue error
    logger.error(exception: error) { "error executing task #{@name}" }
    @state = :exception
    @payload = error.message || "error executing task"
    @backtrace = error.backtrace? || DEFAULT_BACKTR
    @error_class = error.class.to_s
    @channel.close unless @channel.closed?
    if !@complete.closed?
      @complete.send true
      @complete.close
    end
    self
  end

  def complete?
    @complete.closed?
  end

  def get(response_required = false)
    response_required! if response_required
    @channel.receive?
    self
  end

  # This is used by the queue to manage the task
  def __get
    @complete.receive?
  end

  def delay_required?
    delay = @delay
    sleep delay if delay
  end

  # result should support conversion to JSON
  def success(result = nil)
    @state = :success
    @wait = false

    if @response_required
      begin
        @payload = result.try_to_json("null")
      rescue e
        logger.warn(exception: e) { "unable to convert result to JSON" }
      end
    end

    @channel.close
    @complete.send true
    @complete.close
    self
  end

  # A partial response was received
  def reset_timers
    # start if there should be a timer and we are still waiting for a response
    start_timers if @wait && !@channel.closed?
  end

  # Possible failure or device busy.
  def retry(reason = nil)
    return if @wait == false || @channel.closed?

    @retries -= 1
    if @retries >= 0
      logger.info do
        if @name
          "retrying task #{@name.inspect} #{reason}"
        else
          "retrying task #{reason}"
        end
      end

      stop_timers
      @complete.send false
    else
      reason ? abort("retry limit reached (#{reason})") : abort("retry limit reached")
    end
  end

  # Failed except we don't want to retry
  def abort(reason = nil)
    stop_timers
    @wait = false
    @state = :abort
    @payload = reason.to_s if reason
    @channel.close
    @complete.send true
    @complete.close
    logger.warn do
      if @name
        "aborting task, #{@name.inspect}, #{reason}"
      else
        "aborting task, #{reason}"
      end
    end
    self
  end

  private def start_timers
    stop_timers if @timer
    @timer = Tasker.in(@timeout) do
      @timer = nil
      self.retry("due to timeout")
    end
  end

  private def stop_timers
    @timer.try &.cancel
    @timer = nil
  end
end
