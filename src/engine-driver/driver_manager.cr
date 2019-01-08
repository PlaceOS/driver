class EngineDriver::DriverManager
  def initialize(@module_id : String, @model : DriverModel)
    @settings = Settings.new @model.settings.to_json
    @logger = EngineDriver::Logger.new(@module_id)
    @queue = Queue.new(@logger)

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
  macro finished
    macro define_new_driver
      macro new_driver
        {{EngineDriver::CONCRETE_DRIVERS.keys.first}}.new(@module_id, @settings, @queue, @transport, @logger)
      end

      @driver : {{EngineDriver::CONCRETE_DRIVERS.keys.first}}
    end

    define_new_driver
  end

  getter :logger, module_id

  def start
  end

  def stop
  end

  private def received(data, task)
    {% if EngineDriver::CONCRETE_DRIVERS.values.first[0].reject { |method| method.name.stringify != "received" }.size > 0 %}
      @driver.received(data, task)
    {% else %}
      @logger.warn "no received function provided for " + {{EngineDriver::CONCRETE_DRIVERS.keys.first.stringify}} + " (#{@module_id})"
      task.try &.abort("no received function provided")
    {% end %}
  end
end
