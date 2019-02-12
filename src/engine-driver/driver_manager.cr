require "ipaddress"

class EngineDriver::DriverManager
  MulticastRangeV4 = IPAddress.new("224.0.0.0/4")
  MulticastRangeV6 = IPAddress.new("ff00::/8")

  def initialize(@module_id : String, @model : DriverModel, logger_io = STDOUT, subscriptions = Subscriptions.new)
    @settings = Settings.new @model.settings.to_json
    @logger = EngineDriver::Logger.new(@module_id, logger_io)
    @queue = Queue.new(@logger) { |state| connection(state) }
    @schedule = EngineDriver::Proxy::Scheduler.new(@logger)
    @subscriptions = Proxy::Subscriptions.new(subscriptions)

    @state_mutex = Mutex.new

    @transport = case @model.role
                 when DriverModel::Role::SSH
                   ip = @model.ip.not_nil!
                   port = @model.port.not_nil!
                   EngineDriver::TransportSSH.new(@queue, ip, port, @settings) do |data, task|
                     received(data, task)
                   end
                 when DriverModel::Role::RAW
                   ip = @model.ip.not_nil!
                   udp = @model.udp
                   tls = @model.tls
                   port = @model.port.not_nil!
                   makebreak = @model.makebreak

                   if udp
                     begin
                       ipaddr = IPAddress.new(ip)

                       # Check for multicast ranges
                       if ipaddr.is_a?(IPAddress::IPv4) ? MulticastRangeV4.includes?(ipaddr) : MulticastRangeV6.includes?(ipaddr)
                         raise "not implemented"
                       else
                         EngineDriver::TransportUDP.new(@queue, ip, port, tls) do |data, task|
                           received(data, task)
                         end
                       end
                     rescue ArgumentError
                       # Probably a DNS entry
                       EngineDriver::TransportUDP.new(@queue, ip, port, tls) do |data, task|
                         received(data, task)
                       end
                     end
                   elsif makebreak
                     raise "not implemented"
                   else
                     EngineDriver::TransportTCP.new(@queue, ip, port, tls) do |data, task|
                       received(data, task)
                     end
                   end
                 when DriverModel::Role::HTTP
                   EngineDriver::TransportHTTP.new(@queue, @model.uri.not_nil!, @settings)
                 when DriverModel::Role::LOGIC
                   # nothing required to be done here
                   EngineDriver::TransportLogic.new(@queue)
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
        {{EngineDriver::CONCRETE_DRIVERS.keys.first}}.new(@module_id, @settings, @queue, @transport, @logger, @schedule, @subscriptions, @model)
      end

      @driver : {{EngineDriver::CONCRETE_DRIVERS.keys.first}}

      def self.driver_class
        {{EngineDriver::CONCRETE_DRIVERS.keys.first}}
      end

      def self.driver_executor
        {{EngineDriver::CONCRETE_DRIVERS.values.first[1]}}
      end
    end

    define_new_driver
  end

  getter :logger, :module_id, :settings, :queue

  def start
    driver = @driver
    begin
      driver.on_load if driver.responds_to?(:on_load)
      driver.__apply_bindings__
    rescue error
      @logger.error "in the on_load function of #{driver.class} (#{@module_id})\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
    end
    @transport.connect
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