require "ipaddress"
require "promise"

class ACAEngine::Driver::DriverManager
  def initialize(@module_id : String, @model : DriverModel, logger_io = STDOUT, subscriptions = nil)
    subscriptions ||= Subscriptions.new(module_id: @module_id)
    @settings = Settings.new @model.settings
    @logger = ACAEngine::Driver::Logger.new(@module_id, logger_io)
    @queue = Queue.new(@logger) { |state| connection(state) }
    @schedule = ACAEngine::Driver::Proxy::Scheduler.new(@logger)
    @subscriptions = Proxy::Subscriptions.new(subscriptions)

    # Ensures execution all occurs on a single thread
    @requests = ::Channel(Tuple(Promise::DeferredPromise(Nil), Protocol::Request)).new(4)

    @transport = case @model.role
                 when DriverModel::Role::SSH
                   ip = @model.ip.not_nil!
                   port = @model.port.not_nil!
                   ACAEngine::Driver::TransportSSH.new(@queue, ip, port, @settings, @model.uri) do |data, task|
                     received(data, task)
                   end
                 when DriverModel::Role::RAW
                   ip = @model.ip.not_nil!
                   udp = @model.udp
                   tls = @model.tls
                   port = @model.port.not_nil!
                   makebreak = @model.makebreak

                   if udp
                     ACAEngine::Driver::TransportUDP.new(@queue, ip, port, @settings, tls, @model.uri) do |data, task|
                       received(data, task)
                     end
                   else
                     ACAEngine::Driver::TransportTCP.new(@queue, ip, port, @settings, tls, @model.uri, makebreak) do |data, task|
                       received(data, task)
                     end
                   end
                 when DriverModel::Role::HTTP
                   ACAEngine::Driver::TransportHTTP.new(@queue, @model.uri.not_nil!, @settings)
                 when DriverModel::Role::LOGIC
                   # nothing required to be done here
                   ACAEngine::Driver::TransportLogic.new(@queue)
                 else
                   raise "unknown role for driver #{@module_id}"
                 end
    @driver = new_driver
  end

  getter model : ::ACAEngine::Driver::DriverModel

  # This hack is required to "dynamically" load the user defined class
  # The compiler is somewhat fragile when it comes to initializers
  macro finished
    macro define_new_driver
      macro new_driver
        {{ACAEngine::Driver::CONCRETE_DRIVERS.keys.first}}.new(@module_id, @settings, @queue, @transport, @logger, @schedule, @subscriptions, @model)
      end

      @driver : {{ACAEngine::Driver::CONCRETE_DRIVERS.keys.first}}

      def self.driver_class
        {{ACAEngine::Driver::CONCRETE_DRIVERS.keys.first}}
      end

      def self.driver_executor
        {{ACAEngine::Driver::CONCRETE_DRIVERS.values.first[1]}}
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
      @logger.error "in the on_load function of #{driver.class} (#{@module_id})\n#{error.inspect_with_backtrace}"
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
        @logger.error "in the on_unload function of #{driver.class} (#{@module_id})\n#{error.inspect_with_backtrace}"
      end
    end
    @requests.close
    @queue.terminate
    @schedule.terminate
    @subscriptions.terminate
  end

  # TODO:: Core is sending the whole model object - so we should determine if
  # we should stop and start
  def update(driver_model)
    @settings.json = driver_model.settings
    driver = @driver
    driver.on_update if driver.responds_to?(:on_update)
  rescue error
    @logger.error "during settings update of #{@driver.class} (#{@module_id})\n#{error.inspect_with_backtrace}"
  end

  def execute(json)
    executor = {{ACAEngine::Driver::CONCRETE_DRIVERS.values.first[1]}}.new(json)
    executor.execute(@driver)
  end

  private def process_requests!
    loop do
      req_data = @requests.receive?
      break unless req_data

      promise, request = req_data
      spawn(same_thread: true) do
        process request
        promise.resolve(nil)
      end
    end
  end

  private def process(request)
    case request.cmd
    when "exec"
      exec_request = request.payload.not_nil!

      begin
        result = execute exec_request

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
        @logger.error(msg)
        request.set_error(error)
      end
    when "update"
      update(request.driver_model.not_nil!)
    when "stop"
      terminate
    else
      raise "unexpected request"
    end
  rescue error
    @logger.fatal("issue processing requests on #{DriverManager.driver_class} (#{request.id})\n#{error.inspect_with_backtrace}")
    request.set_error(error)
  end

  private def connection(state : Bool) : Nil
    driver = @driver
    begin
      if state
        driver[:connected] = true
        driver.connected if driver.responds_to?(:connected)
      else
        driver[:connected] = false
        driver.disconnected if driver.responds_to?(:disconnected)
      end
    rescue error
      @logger.warn "error changing connected state #{driver.class} (#{@module_id})\n#{error.inspect_with_backtrace}"
    end
  end

  private def received(data, task)
    driver = @driver
    if driver.responds_to? :received
      driver.received(data, task)
    else
      @logger.warn "no received function provided for #{driver.class} (#{@module_id})"
      task.try &.abort("no received function provided")
    end
  end
end
