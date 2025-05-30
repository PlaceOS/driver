require "ipaddress"

# :nodoc:
class PlaceOS::Driver::DriverManager
  def initialize(@module_id : String, @model : DriverModel, logger_io = STDOUT, subscriptions = nil, edge_driver = false)
    @settings = Settings.new @model.settings
    @logger = PlaceOS::Driver::Log.new(@module_id, logger_io)
    @queue = Queue.new(@logger) { |state| connection(state) }
    @schedule = PlaceOS::Driver::Proxy::Scheduler.new(@logger)
    @subscriptions = edge_driver ? nil : Proxy::Subscriptions.new(subscriptions || Subscriptions.new(module_id: @module_id), @logger)
    @calibrate_connected = false

    @transport = case @model.role
                 in .ssh?
                   ip = @model.ip.not_nil!
                   port = @model.port.not_nil!
                   PlaceOS::Driver::TransportSSH.new(@queue, ip, port, @settings, @model.uri) do |data, task|
                     received(data, task)
                   end
                 in .raw?
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
                 in .http?
                   PlaceOS::Driver::TransportHTTP.new(@queue, @model.uri.not_nil!, @settings) do
                     http_received
                   end
                 in .logic?
                   # nothing required to be done here
                   PlaceOS::Driver::TransportLogic.new(@queue)
                 in .websocket?
                   headers_callback = Proc(HTTP::Headers).new { websocket_headers }
                   PlaceOS::Driver::TransportWebsocket.new(@queue, @model.uri.not_nil!, @settings, headers_callback) do |data, task|
                     received(data, task)
                   end
                 end
    @driver = new_driver
  end

  @subscriptions : Proxy::Subscriptions?
  getter model : ::PlaceOS::Driver::DriverModel
  getter calibrate_connected : Bool

  # This hack is required to "dynamically" load the user defined class
  # The compiler is somewhat fragile when it comes to initializers
  macro finished
    macro define_new_driver
      macro new_driver
        {{PlaceOS::Driver::CONCRETE_DRIVERS.keys.first}}.new(@module_id, @settings, @queue, @transport, @logger, @schedule, @subscriptions, @model, edge_driver)
      end

      # :nodoc:
      @driver : {{PlaceOS::Driver::CONCRETE_DRIVERS.keys.first}}

      # :nodoc:
      def self.driver_class
        {{PlaceOS::Driver::CONCRETE_DRIVERS.keys.first}}
      end
    end

    define_new_driver
  end

  getter logger, module_id, settings, queue

  def start
    driver = @driver

    # we don't want to block driver init processing too long
    # a driver might be making a HTTP request in on_load for exampe which
    # could block for a long time, resulting in poor feedback
    if driver.responds_to?(:on_load) || driver.responds_to?(:on_update)
      wait_on_load = Channel(Nil).new
      spawn(same_thread: true) do
        begin
          if driver.responds_to?(:on_load)
            driver.on_load
          elsif driver.responds_to?(:on_update)
            driver.on_update
          end
        rescue error
          logger.error(exception: error) { "initializing #{driver.class} (#{@module_id})" }
        end
        wait_on_load.send nil
      end

      select
      when wait_on_load.receive
      when timeout(6.seconds)
        logger.error { "timeout initializing #{driver.class} (#{@module_id})" }
      end

      wait_on_load.close
    end

    begin
      driver.__apply_bindings__
    rescue error
      logger.error(exception: error) { "error applying bindings of #{driver.class} (#{@module_id})" }
    end

    if @model.makebreak
      @queue.online = true
    else
      spawn(same_thread: true) { @transport.connect }
    end
  end

  def terminate : Nil
    @transport.terminate
    driver = @driver

    @queue.terminate
    @schedule.terminate
    @subscriptions.try &.terminate
  ensure
    if driver.responds_to?(:on_unload)
      wait_on_unload = Channel(Nil).new
      spawn(same_thread: true) do
        begin
          driver.on_unload
        rescue error
          logger.error(exception: error) { "in the wait_on_unload function of #{driver.class} (#{@module_id})" }
        end
        wait_on_unload.send nil
      end

      select
      when wait_on_unload.receive
      when timeout(6.seconds)
        logger.error { "timeout waiting for the wait_on_unload function of #{driver.class} (#{@module_id})" }
      end

      wait_on_unload.close
    end
  end

  # update the modules view of the world
  def update(driver_model) : Nil
    @settings.json = driver_model.settings
    driver = @driver
    driver.config = driver_model
    driver[:proxy_in_use] = nil
    driver.on_update if driver.responds_to?(:on_update)
  rescue error
    logger.error(exception: error) { "during settings update of #{@driver.class} (#{@module_id})" }
  end

  def execute(json)
    executor = {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.new(json)
    executor.execute(@driver)
  end

  protected def spawn_request_fiber(channel, request) : Nil
    spawn(same_thread: true, name: request.user_id) do
      Log.context.set user_id: (request.user_id || "internal"), request_id: request.id
      response = process(request)
      channel.send(response)
    end
  rescue error
    Log.error(exception: error) { "error spawning request fiber" }
  end

  def self.process_result(klass, method_name, ret_val) : String | Task
    return ret_val if ret_val.is_a?(::PlaceOS::Driver::Task)

    # handle futures and promises
    ret_val = ret_val.responds_to?(:get) ? ret_val.get : ret_val

    # convert response to JSON
    case ret_val
    when Array(::Log::Entry)
      ret_val.map(&.message).to_json
    when ::Log::Entry
      ret_val.message.to_json
    when Enum
      ret_val.to_s.to_json
    when JSON::Serializable, Bool
      ret_val.to_json
    else
      begin
        ret_val.try_to_json("null")
      rescue error
        klass.logger.debug(exception: error) { "unable to convert result to json executing #{method_name} on #{klass.class}\n#{ret_val.inspect}" }
        "null"
      end
    end
  end

  protected def process_execute_result(request, result) : Protocol::Request
    case result
    when Task
      # get returns self so outcome is of type Task
      outcome = result.get(:response_required)
      request.payload = outcome.payload
      request.code = outcome.code
      case outcome.state
      in .exception?
        request.code ||= 500
        request.error = outcome.error_class
        request.backtrace = outcome.backtrace
      in .unknown?
        request.code ||= 500
        logger.fatal { "unexpected result: #{outcome.state} - #{outcome.payload}, #{outcome.error_class}, #{outcome.backtrace.join("\n")}" }
      in .abort?
        request.code ||= 500
        request.error = "Abort"
      in .success?
        request.code ||= 200
      end
    else
      request.code ||= 200
      request.payload = result
    end
    request
  end

  macro define_run_execute
    private def run_execute(request) : Protocol::Request
      {% if !::PlaceOS::Driver::RESCUE_FROM.empty? %}
        begin
      {% end %}
        process_execute_result request, execute(request.payload.not_nil!)
      {% if !::PlaceOS::Driver::RESCUE_FROM.empty? %}
        {% for exception, details in ::PlaceOS::Driver::RESCUE_FROM %}
          rescue error : {{exception.id}}
            process_execute_result request, @driver.__handle_rescue_from__(@driver, {{details[0].stringify}}, error)
        {% end %}
        end
      {% end %}
    rescue error
      logger.error(exception: error) { "executing #{request.payload} on #{DriverManager.driver_class} (#{request.id})" }
      request.set_error(error)
    end
  end

  private def process(request) : Protocol::Request?
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
    # this is just a hint so we can ignore it if redis was offline
    check_proxy_usage(driver) rescue nil

    # connected status is more important so we should ensure this is calibrated
    begin
      driver[:connected] = state
      @calibrate_connected = false
    rescue error
      @calibrate_connected = true
      logger.warn(exception: error) { "error setting connected status #{driver.class} (#{@module_id})" }
    end

    # we want to run these callbacks even if redis was offline
    if state
      driver.connected if driver.responds_to?(:connected)
    else
      driver.disconnected if driver.responds_to?(:disconnected)
    end
  rescue error
    logger.warn(exception: error) { "error changing connected state #{@driver.class} (#{@module_id})" }
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

    # ensure connected state is eventually consistent if there was an issue
    # with redis when the connected state changed
    ensure_connected_calibrate(driver) if @calibrate_connected
  end

  protected def http_received
    ensure_connected_calibrate(@driver) if @calibrate_connected
  end

  private def ensure_connected_calibrate(driver) : Nil
    driver[:connected] = true
    check_proxy_usage(driver) rescue nil
    @calibrate_connected = false
  rescue
  end

  private def check_proxy_usage(driver)
    driver[:proxy_in_use] = @transport.proxy_in_use
  end
end
