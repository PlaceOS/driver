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

    @state = @wait ? State::Unknown : State::Success
    @payload = DEFAULT_RESULT
    @backtrace = DEFAULT_BACKTR
    @error_class = nil
  end

  @timer : Tasker::Task?
  @processing : Proc(Bytes, Task, Nil)?
  @error_class : String?

  # the response code that the browser will receive when executing via HTTP
  property code : Int32? = nil

  enum State
    Success
    Abort
    Exception
    Unknown
  end

  getter state : State
  getter last_executed, payload, backtrace, error_class
  getter name, delay, wait
  property processing, retries, priority, clear_queue
  property apparent_priority : Int32 = 0

  # :nodoc:
  # Use the Queue's custom logger
  delegate logger, to: @queue

  # Drivers can monkey patch task if the request is required to process the response
  # @request_payload : Bytes?
  # property :request_payload

  # :nodoc:
  # Are we intending to provide this result to a third party?
  def response_required!
    @response_required = true
    self
  end

  # :nodoc:
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

  # :nodoc:
  def complete?
    @complete.closed?
  end

  # :nodoc:
  def get(response_required = false)
    response_required! if response_required
    @channel.receive?
    self
  end

  # :nodoc:
  # This is used by the queue to manage the task
  def __get
    @complete.receive?
  end

  # :nodoc:
  def delay_required?
    delay = @delay
    sleep delay if delay
  end

  # call when result is a success.
  #
  # The result should support conversion to JSON otherwise the remote will only receive `nil`
  def success(result = nil, @code = 200)
    return self unless @state.unknown?
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
    # the channel might be closed in a response where the tokenizer splits the response
    @complete.send(true) rescue nil
    @complete.close
    self
  end

  # a partial response was received and we don't want the timeout to trigger a retry
  def reset_timers
    # start if there should be a timer and we are still waiting for a response
    start_timers if @wait && !@channel.closed?
  end

  # call when possible temporary failure or device busy
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

  # call when the task has failed and we don't want to retry
  def abort(reason = nil, @code = 500)
    return self unless @state.unknown?
    @state = :abort

    stop_timers
    @wait = false
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

  # :nodoc:
  private def start_timers
    stop_timers if @timer
    @timer = Tasker.in(@timeout) do
      @timer = nil
      self.retry("due to timeout")
    end
  end

  # :nodoc:
  private def stop_timers
    @timer.try &.cancel
    @timer = nil
  end
end
