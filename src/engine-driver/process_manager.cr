require "json"

class EngineDriver::ProcessManager
  def initialize(@logger_io = STDOUT, @input = STDIN, output = STDERR)
    @subscriptions = Subscriptions.new(@logger_io)
    @protocol = EngineDriver::Protocol.new_instance(@input, output)
    @logger = @subscriptions.logger

    @loaded = {} of String => DriverManager

    @protocol.register :start { |request| start(request) }
    @protocol.register :stop { |request| stop(request) }
    @protocol.register :update { |request| update(request) }
    @protocol.register :exec { |request| exec(request) }
    @protocol.register :debug { |request| debug(request) }
    @protocol.register :ignore { |request| ignore(request) }
    @protocol.register :terminate { terminate }

    @terminated = Channel(Nil).new
  end

  @input : IO
  @logger_io : IO
  @logger : ::Logger
  getter :logger, :loaded, terminated

  def start(request : Protocol::Request)
    module_id = request.id
    return if @loaded[module_id]?

    model = EngineDriver::DriverModel.from_json(request.payload.not_nil!)
    driver = DriverManager.new module_id, model, @logger_io, @subscriptions
    @loaded[module_id] = driver
    driver.start
    request.payload = nil
    request
  rescue error
    # Driver was unable to be loaded.
    @logger.error "starting driver #{DriverManager.driver_class} (#{request.id})\n#{error.inspect_with_backtrace}"
    request.set_error(error)
  end

  def stop(request : Protocol::Request) : Nil
    driver = @loaded.delete request.id
    driver.try &.terminate
  rescue error
    @logger.error "stopping driver #{DriverManager.driver_class} (#{request.id})\n#{error.inspect_with_backtrace}"
  end

  def update(request : Protocol::Request) : Nil
    driver = @loaded[request.id]?
    driver.try &.update(request.payload)
  end

  def exec(request : Protocol::Request) : Protocol::Request
    driver = @loaded[request.id]?

    begin
      raise "driver not available" unless driver

      request.cmd = "result"

      exec_request = request.payload.not_nil!
      result = driver.execute exec_request

      # If a task is being returned then we want to wait for the result
      case result
      when Task
        outcome = result.get(:response_required)
        request.payload = outcome.payload

        case outcome.state
        when :success
        when :abort
          request.error = "Abort"
        when :exception
          request.payload = outcome.payload
          request.error = outcome.error_class
          request.backtrace = outcome.backtrace
        when :unknown
          @logger.fatal "unexpected result: #{outcome.state} - #{outcome.payload}, #{outcome.error_class}, #{outcome.backtrace.join("\n")}"
        else
          @logger.fatal "unexpected result: #{outcome.state}"
        end
      else
        request.payload = result
      end
    rescue error
      msg = "executing #{exec_request} on #{DriverManager.driver_class} (#{request.id})\n#{error.inspect_with_backtrace}"
      driver ? driver.logger.error(msg) : @logger.error(msg)
      request.set_error(error)
    end

    request
  end

  def debug(request : Protocol::Request) : Nil
    driver = @loaded[request.id]?
    driver.try &.logger.debugging = true
  end

  def ignore(request : Protocol::Request) : Nil
    driver = @loaded[request.id]?
    driver.try &.logger.debugging = false
  end

  def terminate : Nil
    # Stop the core protocol handler (no more bets)
    @input.close

    # Shutdown all the connections gracefully
    @loaded.each_value &.terminate
    @loaded.clear

    # We now want to stop the subscription loop
    @subscriptions.terminate

    # TODO:: Wait until process have actually completed.
    # Also have a timer that will allow us to force close if required
    @terminated.close
  end
end
