# https://github.com/Sija/retriable.cr#kernel-extension
require "retriable/core_ext/kernel"
require "option_parser"

abstract class EngineDriver
  module Proxy
  end

  def initialize(
    @__module_id__ : String,
    @__settings__ : Settings,
    @__queue__ : Queue,
    @__transport__ : Transport,
    @__logger__ : EngineDriver::Logger,
    @__schedule__ = Proxy::Scheduler.new,
    @__subscriptions__ = Proxy::Subscriptions.new
  )
    @__status__ = Status.new
    @__storage__ = Storage.new(@__module_id__)
    @__storage__.clear
  end

  @__system__ : Proxy::System?

  # Access to the various components
  HELPERS = %w(transport logger settings schedule subscriptions)
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
    @__system__ = Proxy::System.new(system_model, @__subscriptions__)
  end

  # Settings helpers
  macro setting(klass, *types)
    @__settings__.get { setting({{klass}}, {{*types}}) }
  end

  macro setting?(klass, *types)
    @__settings__.get { setting?({{klass}}, {{*types}}) }
  end

  # Queuing
  def queue(*args, &block : Task -> Nil)
    @__queue__.add(*args, &block)
  end

  # Transport
  def send(*args)
    transport.send *args
  end

  # utilities
  def wake_device(mac_address, subnet = "255.255.255.255", port = 9)
    EngineDriver::Utilities.wake_device(mac_address, subnet, port)
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
        __build_helpers__
        {% CONCRETE_DRIVERS[@type] = [@type.methods, (@type.name.id.stringify + "::KlassExecutor").id] %}
    end
  end

  RESERVED_METHODS = {} of Nil => Nil
  {% RESERVED_METHODS["received"] = true %}
  {% RESERVED_METHODS["[]?"] = true %}
  {% RESERVED_METHODS["[]"] = true %}
  {% for name in HELPERS %}
    {% RESERVED_METHODS[name.id.stringify] = true %}
  {% end %}

  macro __build_helpers__
    {% methods = @type.methods %}
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
                  {{arg.name}}: {{arg.restriction}},
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
                {{arg.name.stringify}}: {{arg.restriction.stringify}},
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

        ignore = ["Reference", "Object", "EngineDriver"]

        details = {
          functions: self.functions,
          implements: {{@type.ancestors}}.map(&.to_s).reject { |obj| ignore.includes?(obj) }
        }

        @@metadata = details.to_json
      end

      # TODO::
      def self.defaults : String
        # defaults: (this will indicate default port, module name etc)
        # settings: (this is free form JSON)
        ""
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
                  {{arg.name}}: obj.{{arg.name}},
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
require "./engine-driver/**"

macro finished
  exec_process_manager = false

  # Command line options
  OptionParser.parse(ARGV.dup) do |parser|
    parser.banner = "Usage: #{PROGRAM_NAME} [arguments]"

    parser.on("-m", "--metadata", "output driver metadata") do
      puts {{EngineDriver::CONCRETE_DRIVERS.values.first[1]}}.metadata
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
