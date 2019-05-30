# https://github.com/Sija/retriable.cr#kernel-extension
require "retriable/core_ext/kernel"
require "option_parser"

abstract class EngineDriver
  module Proxy
  end

  module Utilities
  end

  def initialize(
    @__module_id__ : String,
    @__setting__ : Settings,
    @__queue__ : Queue,
    @__transport__ : Transport,
    @__logger__ : EngineDriver::Logger,
    @__schedule__ = Proxy::Scheduler.new,
    @__subscriptions__ = Proxy::Subscriptions.new,
    @__driver_model__ = DriverModel.from_json(%({"udp":false,"tls":false,"makebreak":false,"settings":{},"role":1}))
  )
    @__status__ = Status.new
    @__storage__ = Storage.new(@__module_id__)
    @__storage__.clear
    @__storage__.redis.set("interface\x02#{@__module_id__}", {{EngineDriver::CONCRETE_DRIVERS.values.first[1]}}.metadata)
  end

  @__system__ : Proxy::System?
  @__driver_model__ : DriverModel

  # Access to the various components
  HELPERS = %w(transport logger setting schedule subscriptions)
  {% for name in HELPERS %}
    def {{name.id}}
      @__{{name.id}}__
    end
  {% end %}

  # Status helpers #}
  def []=(key, value)
    key = key.to_s
    json_data, did_change = @__status__.set_json(key, value)
    if did_change
      # using spawn so execution flow isn't interrupted.
      # ensures that setting a key and then reading it back as the next
      # operation will always result in the expected value
      spawn { @__storage__[key] = json_data }
      @__logger__.debug { "status updated: #{key} = #{value}" }
    else
      @__logger__.debug { "no change for: #{key} = #{value}" }
    end
    value
  end

  def [](key)
    @__status__.fetch_json(key)
  end

  def []?(key)
    @__status__.fetch_json?(key)
  end

  def signal_status(key)
    spawn { @__storage__.signal_status(key) }
  end

  def system : Proxy::System
    sys = @__system__
    return sys if sys

    system_model = @__driver_model__.control_system
    raise "not directly associated with a system" unless system_model
    @__system__ = Proxy::System.new(system_model, @__module_id__, @__logger__, @__subscriptions__)
  end

  # Settings helpers
  macro setting(klass, *types)
    @__setting__.get { setting({{klass}}, {{*types}}) }
  end

  macro setting?(klass, *types)
    @__setting__.get { setting?({{klass}}, {{*types}}) }
  end

  def define_setting(name, value)
    EngineDriver::Protocol.instance.request(@__module_id__, "setting", {name, value})
  end

  # Queuing
  def queue(*args, &block : Task -> Nil)
    @__queue__.add(*args, &block)
  end

  # Transport
  def send(message) : Int32
    transport.send message
  end

  def send(message, task : EngineDriver::Task, &block : Bytes -> Nil) : Int32
    transport.send message, task, &block
  end

  # Subscriptions and channels
  def subscribe(status, &callback : (Subscriptions::DirectSubscription, String) -> Nil) : Subscriptions::DirectSubscription
    @__subscriptions__.subscribe(@__module_id__, status.to_s, &callback)
  end

  def publish(channel, message)
    @__storage__.redis.publish("engine\x02#{channel}", message.to_s)
    message
  end

  def monitor(channel, &callback : (Subscriptions::ChannelSubscription, String) -> Nil) : Subscriptions::ChannelSubscription
    @__subscriptions__.channel(channel.to_s, &callback)
  end

  # utilities
  def wake_device(mac_address, subnet = "255.255.255.255", port = 9)
    EngineDriver::Utilities::WakeOnLAN.wake_device(mac_address, subnet, port)
  end

  def set_connected_state(online, status_only = true)
    online = !!online
    if status_only
      @__queue__.set_connected(online)
    else
      @__queue__.online = online
    end
  end

  def disconnect
    @__transport__.disconnect
  end

  # Keep track of loaded driver classes. Should only be one.
  CONCRETE_DRIVERS = {} of Nil => Nil

  # Remote execution helpers
  macro inherited
    macro finished
      {% if !@type.abstract? %}
        __build_helpers__
        {% CONCRETE_DRIVERS[@type] = [@type.methods, (@type.name.id.stringify + "::KlassExecutor").id] %}
        __build_apply_bindings__
      {% end %}
    end
  end

  IGNORE_KLASSES   = ["EngineDriver", "Reference", "Object", "Spec::ObjectExtensions", "Colorize::ObjectExtensions"]
  RESERVED_METHODS = {} of Nil => Nil
  {% RESERVED_METHODS["received"] = true %}
  {% RESERVED_METHODS["[]?"] = true %}
  {% RESERVED_METHODS["[]"] = true %}
  {% RESERVED_METHODS["send"] = true %}
  {% for name in HELPERS %}
    {% RESERVED_METHODS[name.id.stringify] = true %}
  {% end %}

  macro __build_helpers__
    {% methods = @type.methods %}
    {% klasses = @type.ancestors.reject { |a| IGNORE_KLASSES.includes?(a.stringify) } %}
    # {{klasses.map &.stringify}} <- in case we need to filter out more classes
    {% klasses.map { |a| methods = methods + a.methods } %}
    {% methods = methods.reject { |method| RESERVED_METHODS[method.name.stringify] } %}
    {% methods = methods.reject { |method| method.visibility != :public } %}
    {% methods = methods.reject { |method| method.accepts_block? } %}

    # Build a class that represents each method
    {% for method in methods %}
      {% index = 0 %}
      {% args = [] of Crystal::Macros::Arg %}
      {% for arg in method.args %}
        {% if !method.splat_index || index < method.splat_index %}
          {% args << arg %}
        {% end %}
        {% index = index + 1 %}
      {% end %}

      class Method{{method.name.stringify.camelcase.id}}
        JSON.mapping(
          {% if args.size == 0 %}
             {} of String => String
          {% else %}
             {% for arg in args %}
                {% if !arg.restriction %}
                  "Public method '{{@type.id}}.{{method.name}}' has no type specified for argument '{{arg.name}}'"
                {% else %}
                  {% if arg.default_value.is_a?(Nop) %}
                    {{arg.name}}: {{arg.restriction}},
                  {% else %}
                    {{arg.name}}: {{arg.restriction}}?,
                  {% end %}
                {% end %}
            {% end %}
          {% end %}
        )
      end
    {% end %}

    # A class that handles executing every public method defined
    # NOTE:: currently doesn't handle multiple methods signatures (except block
    # and no block). Technically we could add the support however the JSON
    # parsing does not reliably pick the closest match and instead picks the
    # first or simplest match. So simpler to have a single method signature for
    # all public API methods
    class KlassExecutor
      JSON.mapping(
        __exec__: String,
        {% for method in methods %}
            {{method.name}}: Method{{method.name.stringify.camelcase.id}}?,
        {% end %}
      )

      # provide introspection into available functions
      @@functions : String?
      def self.functions : String
        functions = @@functions
        return functions if functions

          list = %({
          {% for method in methods %}
            {% index = 0 %}
            {% args = [] of Crystal::Macros::Arg %}
            {% for arg in method.args %}
              {% if !method.splat_index || index < method.splat_index %}
                {% args << arg %}
              {% end %}
              {% index = index + 1 %}
            {% end %}

            {{method.name.stringify}}: {
              {% for arg in args %}
                {% if arg.default_value.is_a?(Nop) %}
                  {{arg.name.stringify}}: [{{arg.restriction.stringify}}],
                {% else %}
                  {{arg.name.stringify}}: [{{arg.restriction.stringify}}, "#{{{arg.default_value}}.to_json}"],
                {% end %}
              {% end %}
            },
          {% end %}})

        # Remove whitespace, remove all ',' followed by a '}'
        @@functions = list.gsub(/\s/, "").gsub(",}", "}")
      end

      @@metadata : String?
      def self.metadata : String
        metadata = @@metadata
        return metadata if metadata

        implements = {{@type.ancestors.map(&.stringify)}}.reject { |obj| IGNORE_KLASSES.includes?(obj) }
        details = %({
          "functions": #{self.functions},
          "implements": #{implements.to_json},
          "requirements": #{Utilities::Discovery.requirements.to_json}
        }).gsub(/\s/, "")

        @@metadata = details
      end

      # Once serialised, we want to execute the request on the class
      def execute(klass : {{@type.id}})
        case self.__exec__
        {% for method in methods %}
          {% index = 0 %}
          {% args = [] of Crystal::Macros::Arg %}
          {% for arg in method.args %}
            {% if !method.splat_index || index < method.splat_index %}
              {% args << arg %}
            {% end %}
            {% index = index + 1 %}
          {% end %}

          when {{method.name.stringify}}
            {% if args.size == 0 %}
              return klass.{{method.name}}
            {% else %}
              obj = self.{{method.name}}.not_nil!
              args = {
                {% for arg in args %}
                  {% if arg.default_value.is_a?(Nop) %}
                    {{arg.name}}: obj.{{arg.name}},
                  {% else %}
                    {{arg.name}}: obj.{{arg.name}} || {{arg.default_value}},
                  {% end %}
                {% end %}
              }
              return klass.{{method.name}} **args
            {% end %}
        {% end %}
        end

        raise "execute request for unknown method: #{self.__exec__}"
      end
    end
  end
end

require "./engine-driver/*"
require "./engine-driver/proxy/*"
require "./engine-driver/subscriptions/*"
require "./engine-driver/transport/*"
require "./engine-driver/utilities/*"

macro finished
  exec_process_manager = false

  # Command line options
  OptionParser.parse(ARGV.dup) do |parser|
    parser.banner = "Usage: #{PROGRAM_NAME} [arguments]"

    parser.on("-m", "--metadata", "output driver metadata") do
      puts {{EngineDriver::CONCRETE_DRIVERS.values.first[1]}}.metadata
      exit 0
    end

    parser.on("-d", "--defaults", "output driver defaults") do
      puts EngineDriver::Utilities::Discovery.defaults
      exit 0
    end

    parser.on("-p", "--process", "starts the process manager (expects to have been launched by engine core)") do
      exec_process_manager = true
    end

    parser.on("-h", "--help", "show this help") do
      puts parser
      exit 0
    end
  end

  # Launch the process manager by default, this can be overriten for testing
  if exec_process_manager
    process = EngineDriver::ProcessManager.new

    # Detect ctr-c to shutdown gracefully
    Signal::INT.trap do |signal|
      puts " > terminating gracefully"
      spawn { process.terminate }
      signal.ignore
    end

    process.terminated.receive?
  end
end

nil
