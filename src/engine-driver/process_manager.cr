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

  def start(request : Protocol::Request, driver_model = nil)
    module_id = request.id
    return if @loaded[module_id]?

    model = driver_model || EngineDriver::DriverModel.from_json(request.payload.not_nil!)
    driver = DriverManager.new module_id, model, @logger_io, @subscriptions
    @loaded[module_id] = driver

    # Drivers can all run on a different thread
    spawn { driver.start }
    request.payload = nil
    request
  rescue error
    # Driver was unable to be loaded.
    @logger.error "starting driver #{DriverManager.driver_class} (#{request.id})\n#{error.inspect_with_backtrace}"
    request.set_error(error)
  end

  def stop(request : Protocol::Request) : Nil
    driver = @loaded.delete request.id
    if driver
      promise = Promise.new(Nil)
      driver.requests.send({promise, request})
      promise.get
    end
  end

  def update(request : Protocol::Request) : Nil
    module_id = request.id
    driver = @loaded[module_id]?
    return unless driver
    existing = driver.model
    updated = EngineDriver::DriverModel.from_json(request.payload.not_nil!)

    # Check if there are changes that require module restart
    if (
      updated.ip != existing.ip || updated.udp != existing.udp ||
      updated.tls != existing.tls || updated.port != existing.port ||
      updated.makebreak != existing.makebreak || updated.uri != existing.uri ||
      updated.role != existing.role
    )
      # Change required
      stop request
      start request, updated
    else
      # No change required
      request.driver_model = updated
      promise = Promise.new(Nil)
      driver.requests.send({promise, request})
      promise.get
    end
  end

  def exec(request : Protocol::Request) : Protocol::Request
    driver = @loaded[request.id]?

    begin
      raise "driver not available" unless driver

      promise = Promise.new(Nil)
      driver.requests.send({promise, request})
      promise.get
    rescue error
      @logger.error("executing #{request.payload} on #{DriverManager.driver_class} (#{request.id})\n#{error.inspect_with_backtrace}")
      request.set_error(error)
    end

    request.cmd = "result"
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
    req = Protocol::Request.new("", "stop")
    @loaded.each_value do |driver|
      promise = Promise.new(Nil)
      driver.requests.send({promise, req})
      promise.get
    end
    @loaded.clear

    # We now want to stop the subscription loop
    @subscriptions.terminate

    # TODO:: Wait until process have actually completed.
    # Also have a timer that will allow us to force close if required
    @terminated.close
  end
end
