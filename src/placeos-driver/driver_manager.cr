require "ipaddress"
require "promise"

class PlaceOS::Driver::DriverManager
  def initialize(@module_id : String, @model : DriverModel, logger_io = STDOUT, subscriptions = nil, edge_driver = false)
    @settings = Settings.new @model.settings
    @logger = PlaceOS::Driver::Log.new(@module_id, logger_io)
    @queue = Queue.new(@logger) { |state| connection(state) }
    @schedule = PlaceOS::Driver::Proxy::Scheduler.new(@logger)
    @subscriptions = edge_driver ? nil : Proxy::Subscriptions.new(subscriptions || Subscriptions.new(module_id: @module_id))

    # Ensures execution all occurs on a single thread
    @requests = ::Channel(Tuple(Promise::DeferredPromise(Nil), Protocol::Request)).new(4)

    @transport = case @model.role
                 when DriverModel::Role::SSH
                   ip = @model.ip.not_nil!
                   port = @model.port.not_nil!
                   PlaceOS::Driver::TransportSSH.new(@queue, ip, port, @settings, @model.uri) do |data, task|
                     received(data, task)
                   end
                 when DriverModel::Role::RAW
                   ip = @model.ip.not_nil!
                   udp = @model.udp
                   tls = @model.tls
                   port = @model.port.not_nil!
                   makebreak = @model.makebreak

                   if udp
                     PlaceOS::Driver::TransportUDP.new(@queue, ip, port, @settings, tls, @model.uri) do |data, task|
                       received(data, task)
                     end
                   else
                     PlaceOS::Driver::TransportTCP.new(@queue, ip, port, @settings, tls, @model.uri, makebreak) do |data, task|
                       received(data, task)
                     end
                   end
                 when DriverModel::Role::HTTP
                   PlaceOS::Driver::TransportHTTP.new(@queue, @model.uri.not_nil!, @settings)
                 when DriverModel::Role::LOGIC
                   # nothing required to be done here
                   PlaceOS::Driver::TransportLogic.new(@queue)
                 when DriverModel::Role::WEBSOCKET
                   headers_callback = Proc(HTTP::Headers).new { websocket_headers }
                   PlaceOS::Driver::TransportWebsocket.new(@queue, @model.uri.not_nil!, @settings, headers_callback) do |data, task|
                     received(data, task)
                   end
                 else
                   raise "unknown role for driver #{@module_id}"
                 end
    @driver = new_driver
  end

  @subscriptions : Proxy::Subscriptions?
  getter model : ::PlaceOS::Driver::DriverModel

  # This hack is required to "dynamically" load the user defined class
  # The compiler is somewhat fragile when it comes to initializers
  macro finished
    macro define_new_driver
      macro new_driver
        {{PlaceOS::Driver::CONCRETE_DRIVERS.keys.first}}.new(@module_id, @settings, @queue, @transport, @logger, @schedule, @subscriptions, @model, edge_driver)
      end

      @driver : {{PlaceOS::Driver::CONCRETE_DRIVERS.keys.first}}

      def self.driver_class
        {{PlaceOS::Driver::CONCRETE_DRIVERS.keys.first}}
      end

      def self.driver_executor
        {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}
      end
    end

    define_new_driver
  end

  getter logger, module_id, settings, queue, requests

  def start
    driver = @driver

    begin
      driver.on_load if driver.responds_to?(:on_load)
      driver.__apply_bindings__
    rescue error
      logger.error(exception: error) { "in the on_load function of #{driver.class} (#{@module_id})" }
    end

    if @model.makebreak
      @queue.online = true
    else
      spawn(same_thread: true) { @transport.connect }
    end

    # Ensures all requests are running on this thread
    spawn(same_thread: true) { process_requests! }
  end

  def terminate : Nil
    @transport.terminate
    driver = @driver
    if driver.responds_to?(:on_unload)
      begin
        driver.on_unload
      rescue error
        logger.error(exception: error) { "in the on_unload function of #{driver.class} (#{@module_id})" }
      end
    end
    @requests.close
    @queue.terminate
    @schedule.terminate
    @subscriptions.try &.terminate
  end

  # TODO:: Core is sending the whole model object - so we should determine if
  # we should stop and start
  def update(driver_model)
    @settings.json = driver_model.settings
    driver = @driver
    driver[:using_proxy] = nil
    driver.on_update if driver.responds_to?(:on_update)
  rescue error
    logger.error(exception: error) { "during settings update of #{@driver.class} (#{@module_id})" }
  end

  def execute(json)
    executor = {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.new(json)
    executor.execute(@driver)
  end

  private def process_requests!
    loop do
      req_data = @requests.receive?
      break if req_data.nil?
      promise, request = req_data
      spawn(same_thread: true, name: request.user_id) do
        Log.context.set user_id: (request.user_id || "internal"), request_id: request.id
        process request
        promise.resolve(nil)
      end
    end
  end

  private def run_execute(request)
    case result = execute(request.payload.not_nil!)
    when Task
      outcome = result.get(:response_required)
      request.payload = outcome.payload
      case outcome.state
      in .exception?
        request.error = outcome.error_class
        request.backtrace = outcome.backtrace
      in .unknown?
        logger.fatal { "unexpected result: #{outcome.state} - #{outcome.payload}, #{outcome.error_class}, #{outcome.backtrace.join("\n")}" }
      in .abort? then request.error = "Abort"
      in .success?
      end
    else
      request.payload = result
    end
  rescue error
    logger.error(exception: error) { "executing #{request.payload} on #{DriverManager.driver_class} (#{request.id})" }
    request.set_error(error)
  end

  private def process(request)
    case request.cmd
    when .exec?   then run_execute(request)
    when .update? then update(request.driver_model.not_nil!)
    when .stop?   then terminate
    else
      raise "unexpected request: #{request.cmd}"
    end
  rescue error
    logger.fatal(exception: error) { "issue processing requests on #{DriverManager.driver_class} (#{request.id})" }
    request.set_error(error)
  end

  private def connection(state : Bool) : Nil
    driver = @driver
    begin
      if state
        check_proxy_usage(driver)
        driver[:connected] = true
        driver.connected if driver.responds_to?(:connected)
      else
        check_proxy_usage(driver)
        driver[:connected] = false
        driver.disconnected if driver.responds_to?(:disconnected)
      end
    rescue error
      logger.warn(exception: error) { "error changing connected state #{driver.class} (#{@module_id})" }
    end
  end

  private def websocket_headers : HTTP::Headers
    driver = @driver
    if driver.responds_to?(:websocket_headers)
      driver.websocket_headers
    else
      HTTP::Headers.new
    end
  rescue error
    logger.info(exception: error) { "error building websocket headers" }
    HTTP::Headers.new
  end

  private def received(data, task)
    driver = @driver
    if driver.responds_to? :received
      driver.received(data, task)
    else
      logger.warn { "no received function provided for #{driver.class} (#{@module_id})" }
      task.try &.abort("no received function provided")
    end
  end

  private def check_proxy_usage(driver)
    driver[:using_proxy] = @transport.using_proxy.nil? ? nil : @transport.using_proxy
  end
end
