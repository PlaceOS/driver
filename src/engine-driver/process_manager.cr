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
    module_id = request.id
    driver = @loaded.delete module_id
    return unless driver

    driver.terminate
    nil
  rescue error
    @logger.error "stopping driver #{DriverManager.driver_class} (#{request.id})\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
  end

  def update(request : Protocol::Request)
  end

  def exec(request : Protocol::Request)
  end

  def debug(request : Protocol::Request)
  end

  def ignore(request : Protocol::Request)
  end

  def terminate
    # Stop the core protocol handler (no more bets)
    @input.close

    # Shutdown all the connections gracefully
    @subscriptions.terminate
    @loaded.each &.terminate
    @loaded.clear
    nil
  end
end
