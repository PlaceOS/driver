class EngineDriver::DriverManager
  def initialize(@module_id : String, @model : DriverModel, logger_io = STDOUT, subscriptions = Subscriptions.new)
    @settings = Settings.new @model.settings.to_json
    @logger = EngineDriver::Logger.new(@module_id, logger_io)
    @queue = Queue.new(@logger) { |state| connection(state) }
    @schedule = EngineDriver::Proxy::Scheduler.new(@logger)
    @subscriptions = Proxy::Subscriptions.new(subscriptions)

    @state_mutex = Mutex.new

    @transport = case @model.role
                 when DriverModel::Role::SSH
                   raise "not implemented"
                 when DriverModel::Role::RAW
                   ip = @model.ip.not_nil!
                   udp = @model.udp
                   port = @model.port.not_nil!
                   makebreak = @model.makebreak

                   if udp
                     raise "not implemented"
                   elsif makebreak
                     raise "not implemented"
                   else
                     EngineDriver::TransportTCP.new(@queue, ip, port) do |data, task|
                       received(data, task)
                     end
                   end
                 when DriverModel::Role::HTTP
                   raise "not implemented"
                 when DriverModel::Role::LOGIC
                   raise "not implemented"
                 else
                   raise "unknown role for driver #{@module_id}"
                 end
    @driver = new_driver
  end

  # This hack is required to "dynamically" load the user defined class
  # The compiler is somewhat fragile when it comes to initializers
  macro finished
    macro define_new_driver
      macro new_driver
        {{EngineDriver::CONCRETE_DRIVERS.keys.first}}.new(@module_id, @settings, @queue, @transport, @logger, @schedule, @subscriptions)
      end

      @driver : {{EngineDriver::CONCRETE_DRIVERS.keys.first}}

      def self.driver_class
        {{EngineDriver::CONCRETE_DRIVERS.keys.first}}
      end

      def self.driver_executor
        {{EngineDriver::CONCRETE_DRIVERS.keys.first}}::KlassExecutor
      end
    end

    define_new_driver
  end

  getter :logger, :module_id, :settings, :queue

  def start
    driver = @driver
    if driver.responds_to?(:on_load)
      begin
        driver.on_load
      rescue error
        @logger.error "in the on_load function of #{driver.class} (#{@module_id})\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
      end
      @transport.connect
    end
  end

  def terminate : Nil
    @transport.terminate
    driver = @driver
    if driver.responds_to?(:on_unload)
      begin
        driver.on_unload
      rescue error
        @logger.error "in the on_unload function of #{driver.class} (#{@module_id})\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
      end
    end
    @schedule.terminate
    @subscriptions.terminate
  end

  def update(settings)
    @settings.json = JSON.parse(settings.not_nil!)
    driver = @driver
    driver.on_update if driver.responds_to?(:on_update)
  rescue error
    @logger.error "during settings update of #{@driver.class} (#{@module_id})\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
  end

  def execute(json)
    executor = {{EngineDriver::CONCRETE_DRIVERS.values.first[1]}}.from_json(json)
    executor.execute(@driver)
  end

  private def connection(state : Bool) : Nil
    driver = @driver
    begin
      if state
        @state_mutex.synchronize do
          driver[:connected] = true
          driver.connected if driver.responds_to?(:connected)
        end
      else
        @state_mutex.synchronize do
          driver[:connected] = false
          driver.disconnected if driver.responds_to?(:disconnected)
        end
      end
    rescue error
      @logger.warn "error changing connected state #{driver.class} (#{@module_id})\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
    end
  end

  private def received(data, task)
    {% if EngineDriver::CONCRETE_DRIVERS.values.first[0].reject { |method| method.name.stringify != "received" }.size > 0 %}
      @driver.received(data, task)
    {% else %}
      @logger.warn "no received function provided for #{@driver.class} (#{@module_id})"
      task.try &.abort("no received function provided")
    {% end %}
  end
end
