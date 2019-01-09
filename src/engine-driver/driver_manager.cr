class EngineDriver::DriverManager
  def initialize(@module_id : String, @model : DriverModel)
    @settings = Settings.new @model.settings.to_json
    @logger = EngineDriver::Logger.new(@module_id)
    @queue = Queue.new(@logger) { |state| connection(state) }

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
        {{EngineDriver::CONCRETE_DRIVERS.keys.first}}.new(@module_id, @settings, @queue, @transport, @logger)
      end

      @driver : {{EngineDriver::CONCRETE_DRIVERS.keys.first}}

      def self.driver_class
        {{EngineDriver::CONCRETE_DRIVERS.keys.first}}
      end
    end

    define_new_driver
  end

  getter :logger, module_id

  def start
    if @driver.responds_to?(:on_load)
      begin
        @driver.on_load
      rescue error
        @logger.error "an error occured in the on_unload function of #{@driver.class} (#{@module_id})\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
      end
      @transport.connect
    end
  end

  def stop
    @transport.terminate
    if @driver.responds_to?(:on_unload)
      begin
        @driver.on_unload
      rescue error
        @logger.error "an error occured in the on_unload function of #{@driver.class} (#{@module_id})\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
      end
    end
  end

  private def connection(state : Bool) : Nil
    begin
      driver = @driver
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
      @logger.warn "error changing connected state #{@driver.class} (#{@module_id})\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
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
