require "json"
require "./logger"

module PlaceOS::Driver::ProcessManagerInterface
  abstract def start(request : Protocol::Request, driver_model = nil) : Protocol::Request
  abstract def stop(request : Protocol::Request) : Nil
  abstract def update(request : Protocol::Request) : Nil
  abstract def exec(request : Protocol::Request) : Protocol::Request
  abstract def debug(request : Protocol::Request) : Nil
  abstract def ignore(request : Protocol::Request) : Nil
  abstract def info(request : Protocol::Request) : Protocol::Request
  abstract def terminate : Nil
end

# :nodoc:
class PlaceOS::Driver::ProcessManager
  include PlaceOS::Driver::ProcessManagerInterface

  Log = ::Log.for(self, ::Log::Severity::Info)

  def initialize(@logger_io = ::PlaceOS::Driver.logger_io, @input = STDIN, @edge_driver = false)
    @subscriptions = @edge_driver ? nil : Subscriptions.new
  end

  private getter input : IO
  private getter logger_io : IO

  private getter subscriptions : Subscriptions?
  private getter? edge_driver : Bool

  getter loaded : Hash(String, DriverManager) { {} of String => DriverManager }
  getter terminated : Channel(Nil) { Channel(Nil).new }

  def start(request : Protocol::Request, driver_model = nil) : Protocol::Request
    module_id = request.id
    if loaded[module_id]?
      request.payload = nil
      return request
    end

    model = driver_model || PlaceOS::Driver::DriverModel.from_json(request.payload.not_nil!)
    driver = DriverManager.new(module_id, model, logger_io, @subscriptions, edge_driver?)
    loaded[module_id] = driver

    # Drivers can all run on a different thread
    spawn(same_thread: true) { driver.start }
    request.payload = nil
    request
  rescue error
    # Driver was unable to be loaded.
    Log.error(exception: error) { "starting driver #{DriverManager.driver_class} (#{request.id})\nrequest payload: #{request.payload}" }
    loaded.delete(module_id)
    request.set_error(error)
  end

  def stop(request : Protocol::Request) : Nil
    driver = loaded.delete request.id
    if driver
      channel = Channel(Nil).new.tap { |chan| driver.spawn_request_fiber(chan, request) }
      channel.receive
      channel.close
    end
  end

  def update(request : Protocol::Request) : Nil
    module_id = request.id
    driver = loaded[module_id]?
    return unless driver
    existing = driver.model
    updated = PlaceOS::Driver::DriverModel.from_json(request.payload.not_nil!)

    # Check if there are changes that require module restart
    if updated.ip != existing.ip || updated.udp != existing.udp ||
       updated.tls != existing.tls || updated.port != existing.port ||
       updated.makebreak != existing.makebreak || updated.uri != existing.uri ||
       updated.role != existing.role
      # Change required
      stop request
      start request, updated
    else
      # No change required
      request.driver_model = updated
      channel = Channel(Nil).new.tap { |chan| driver.spawn_request_fiber(chan, request) }
      channel.receive
      channel.close
    end
  end

  def exec(request : Protocol::Request) : Protocol::Request
    driver = loaded[request.id]?
    raise "driver not available" unless driver

    channel = Channel(Nil).new.tap { |chan| driver.spawn_request_fiber(chan, request) }
    channel.receive
    channel.close
    request.cmd = :result
    request
  rescue error
    Log.error(exception: error) { "executing #{request.payload} on #{DriverManager.driver_class} (#{request.id})" }
    request.set_error(error)
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
    request = Protocol::Request.new("", :stop)
    loaded.map { |_key, driver|
      Channel(Nil).new.tap { |chan| driver.spawn_request_fiber(chan, request) }
    }.each do |channel|
      channel.receive
      channel.close
    end
    loaded.clear

    # We now want to stop the subscription loop
    subscriptions.try &.terminate

    # TODO:: Wait until process have actually completed.
    # Also have a timer that will allow us to force close if required
    terminated.close
  end
end
