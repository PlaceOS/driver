require "json"

class EngineDriver::ProcessManager
  def initialize(@input = STDIN, output = STDERR)
    @subscriptions = Subscriptions.new
    @protocol = EngineDriver::Protocol.instance(@input, output)
    @logger = @subscriptions.logger

    @loaded = {} of String => DriverManager

    @protocol.register :start { |request| start(request) }
    @protocol.register :stop { |request| stop(request) }
    @protocol.register :update { |request| update(request) }
    @protocol.register :exec { |request| exec(request) }
    @protocol.register :debug { |request| debug(request) }
    @protocol.register :ignore { |request| ignore(request) }
    @protocol.register :terminate { terminate }
  end

  @input : IO
  @logger : ::Logger
  getter :logger

  def start(request : Protocol::Request)
    module_id = request.id
    return if @loaded[module_id]?

    model = EngineDriver::DriverModel.from_json(request.payload.not_nil!)
    driver = DriverManager.new module_id, model
    @loaded[module_id] = driver
    nil
  rescue error
    @logger.error "starting driver #{DriverManager.driver_class} (#{request.id})\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
    request.set_error(error)
  end

  def stop(request : Protocol::Request)
    driver = @loaded.delete request.id
    driver.try &.terminate
    nil
  rescue error
    @logger.error "stopping driver #{DriverManager.driver_class} (#{request.id})\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
  end

  def update(request : Protocol::Request)
    driver = @loaded[request.id]?
    driver.try &.update(request.payload)
    nil
  end

  def exec(request : Protocol::Request) : Protocol::Request
    driver = @loaded[request.id]?
    return nil unless driver

    request.cmd = "result"

    begin
      exec_request = request.payload
      result = driver.execute exec_request

      # If a task is being returned then we want to wait for the result
      if result.is_a?(Task)
        result.response_required!
        outcome = result.get

        request.payload = outcome.payload

        case outcome.result
        when :success
        when :abort
          request.error = "Abort"
        when :exception
          request.payload = outcome.payload
          request.error = outcome.error
          request.backtrace = outcome.backtrace
        when :unknown
          @logger.fatal "unexpected result: #{outcome.result}"
        else
          @logger.fatal "unexpected result: #{outcome.result}"
        end
      elsif result.responds_to?(:to_json)
        begin
          request.payload = result.to_json
        rescue error
          request.payload = "null"
          driver.logger.info { "unable to convert result to json executing #{exec_request} on #{DriverManager.driver_class} (#{@module_id})\n#{error.message}\n#{error.backtrace?.try &.join("\n")}" }
        end
      else
        request.payload = "null"
      end
    rescue error
      driver.logger.error "executing #{exec_request} on #{DriverManager.driver_class} (#{@module_id})\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
      request.set_error(error)
    end

    request
  end

  def debug(_request)
    driver = @loaded[request.id]?
    driver.try &.logger.debugging = true
    nil
  end

  def ignore(_request)
    driver = @loaded[request.id]?
    driver.try &.logger.debugging = false
    nil
  end

  def terminate
    # Stop the core protocol handler (no more bets)
    @input.close

    # Shutdown all the connections gracefully
    @loaded.each &.terminate
    @loaded.clear

    # We now want to stop the subscription loop
    @subscriptions.terminate
    nil
  end
end
