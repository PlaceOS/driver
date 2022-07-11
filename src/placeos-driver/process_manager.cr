require "json"
require "./logger"

class PlaceOS::Driver::ProcessManager
  Log = ::Log.for(self, ::Log::Severity::Info)

  def initialize(@logger_io = ::PlaceOS::Driver.logger_io, @input = STDIN, output = STDERR, @edge_driver = false)
    @subscriptions = @edge_driver ? nil : Subscriptions.new
    @protocol = PlaceOS::Driver::Protocol.new_instance(@input, output)
    @protocol.register :start { |request| start(request) }
    @protocol.register :stop { |request| stop(request) }
    @protocol.register :update { |request| update(request) }
    @protocol.register :exec { |request| exec(request) }
    @protocol.register :debug { |request| debug(request) }
    @protocol.register :ignore { |request| ignore(request) }
    @protocol.register :info { |request| info(request) }
    @protocol.register :terminate { terminate }
  end

  private getter input : IO
  private getter logger_io : IO

  private getter subscriptions : Subscriptions?
  private getter? edge_driver : Bool

  getter loaded : Hash(String, DriverManager) { {} of String => DriverManager }
  getter terminated : Channel(Nil) { Channel(Nil).new }

  def start(request : Protocol::Request, driver_model = nil)
    module_id = request.id
    return if loaded[module_id]?

    model = driver_model || PlaceOS::Driver::DriverModel.from_json(request.payload.not_nil!)

    driver = DriverManager.new(module_id, model, logger_io, @subscriptions, edge_driver?)

    loaded[module_id] = driver

    # Drivers can all run on a different thread
    spawn(same_thread: true) { driver.start }
    request.payload = nil
    request
  rescue error
    # Driver was unable to be loaded.
    Log.error(exception: error) { "starting driver #{DriverManager.driver_class} (#{request.id})" }
    loaded.delete(module_id)
    request.set_error(error)
  end

  def stop(request : Protocol::Request) : Nil
    driver = loaded.delete request.id
    if driver
      Promise.new(Nil).tap { |promise| driver.requests.send({promise, request}) }.get
    end
  end

  def update(request : Protocol::Request) : Nil
    module_id = request.id
    driver = loaded[module_id]?
    return unless driver
    existing = driver.model
    updated = PlaceOS::Driver::DriverModel.from_json(request.payload.not_nil!)

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
    driver = loaded[request.id]?
    raise "driver not available" unless driver

    promise = Promise.new(Nil)
    driver.requests.send({promise, request})
    promise.get

    request.cmd = :result
    request
  rescue error
    Log.error(exception: error) { "executing #{request.payload} on #{DriverManager.driver_class} (#{request.id})" }
    request.set_error(error)
    request
  end

  def debug(request : Protocol::Request) : Nil
    driver = loaded[request.id]?
    driver.try &.logger.debugging = true
  end

  def ignore(request : Protocol::Request) : Nil
    driver = loaded[request.id]?
    driver.try &.logger.debugging = false
  end

  def info(request : Protocol::Request) : Protocol::Request
    request.payload = loaded.keys.to_json
    request.cmd = :result
    request
  end

  def terminate : Nil
    # Stop the core protocol handler (no more bets)
    input.close

    # Shutdown all the connections gracefully
    req = Protocol::Request.new("", :stop)
    loaded.map { |_key, driver|
      Promise.new(Nil).tap { |promise| driver.requests.send({promise, req}) }
    }.each(&.get)
    loaded.clear

    # We now want to stop the subscription loop
    subscriptions.try &.terminate

    # TODO:: Wait until process have actually completed.
    # Also have a timer that will allow us to force close if required
    terminated.close
  end
end
