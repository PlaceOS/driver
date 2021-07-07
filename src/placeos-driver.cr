require "option_parser"
require "./placeos-driver/logger"

class PlaceOS::Startup
  class_property exec_process_manager : Bool = false
  class_property is_edge_driver : Bool = false
  class_property print_meta : Bool = false
  class_property print_defaults : Bool = false
end

# Command line options
OptionParser.parse(ARGV.dup) do |parser|
  parser.banner = "Usage: #{PROGRAM_NAME} [arguments]"

  parser.on("-m", "--metadata", "output driver metadata") do
    PlaceOS::Startup.print_meta = true
  end

  parser.on("-d", "--defaults", "output driver defaults") do
    PlaceOS::Startup.print_defaults = true
  end

  parser.on("-p", "--process", "starts the process manager (expects to have been launched by PlaceOS core)") do
    PlaceOS::Startup.exec_process_manager = true
    PlaceOS::Startup.print_defaults = false
    PlaceOS::Startup.print_meta = false
  end

  parser.on("-e", "--edge", "launches in edge mode") do
    PlaceOS::Startup.is_edge_driver = true
  end

  parser.on("-h", "--help", "show this help") do
    puts parser
    exit 0
  end
end

# If we are launching for the purposes of printing messages then we want to
# disable outputting of log messages
if PlaceOS::Startup.print_meta || PlaceOS::Startup.print_defaults
  Log.setup do |c|
    backend = Log::IOBackend.new
    c.bind "*", :fatal, backend
  end
end

abstract class PlaceOS::Driver
  class_property include_json_schema_in_interface : Bool = true

  module Proxy
  end

  module Utilities
  end

  annotation Security
  end

  enum Level
    Support
    Administrator
  end

  def initialize(
    @__module_id__ : String,
    @__setting__ : Settings,
    @__queue__ : Queue,
    @__transport__ : Transport,
    @__logger__ : PlaceOS::Driver::Log,
    @__schedule__ = Proxy::Scheduler.new,
    @__subscriptions__ = Proxy::Subscriptions.new,
    @__driver_model__ = DriverModel.from_json(%({"udp":false,"tls":false,"makebreak":false,"settings":{},"role":1})),
    @__edge_driver__ : Bool = false
  )
    @__status__ = Status.new

    metadata = {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.driver_interface
    if @__edge_driver__
      @__storage__ = EdgeStorage.new(@__module_id__)
      @__storage__.clear
      PlaceOS::Driver::Protocol.instance.request("interface/#{@__module_id__}", "set", metadata, raw: true)
    else
      redis_store = RedisStorage.new(@__module_id__)
      @__storage__ = redis_store
      redis_store.clear
      RedisStorage.with_redis &.set("interface/#{@__module_id__}", metadata)
    end
  end

  @__system__ : Proxy::System?
  @__storage__ : Storage
  @__driver_model__ : DriverModel
  @__subscriptions__ : Proxy::Subscriptions?

  # Access to the various components
  HELPERS = %w(transport logger queue setting schedule)
  {% for name in HELPERS %}
    def {{name.id}}
      @__{{name.id}}__
    end
  {% end %}

  def subscriptions
    raise "unsupported when running on the edge" if @__edge_driver__
    @__subscriptions__.not_nil!
  end

  def config
    @__driver_model__
  end

  def module_id
    @__module_id__
  end

  # Status helpers #}
  def []=(key, value)
    key = key.to_s
    json_data, did_change = @__status__.set_json(key, value)
    if did_change
      # using spawn so execution flow isn't interrupted.
      # ensures that setting a key and then reading it back as the next
      # operation will always result in the expected value
      spawn(same_thread: true) { @__storage__[key] = json_data }
      @__logger__.debug { "status updated: #{key} = #{json_data}" }
    else
      @__logger__.debug { "no change for: #{key} = #{json_data}" }
    end
    value
  end

  def [](key)
    @__status__.fetch_json(key)
  end

  def []?(key)
    @__status__.fetch_json?(key)
  end

  macro status(klass, key)
    {{klass}}.from_json(@__status__[{{key}}.to_s])
  end

  macro status?(klass, key)
    %value = @__status__[{{key}}.to_s]?
    {{klass}}.from_json(%value) if %value
  end

  def signal_status(key)
    spawn(same_thread: true) { @__storage__.signal_status(key) }
  end

  def system : Proxy::System
    sys = @__system__
    return sys if sys

    system_model = @__driver_model__.control_system
    raise "not directly associated with a system" unless system_model
    @__system__ = Proxy::System.new(system_model, @__module_id__, @__logger__, @__subscriptions__.not_nil!)
  end

  def system(id : String) : Proxy::System
    Proxy::System.new(id, @__module_id__, @__logger__, @__subscriptions__.not_nil!)
  end

  # Settings helpers
  macro setting(klass, *types)
    @__setting__.get { setting({{klass}}, {{*types}}) }
  end

  macro setting?(klass, *types)
    @__setting__.get { setting?({{klass}}, {{*types}}) }
  end

  def define_setting(name, value)
    PlaceOS::Driver::Protocol.instance.request(@__module_id__, "setting", {name, value})
  end

  # Queuing
  def queue(**opts, &block : Task -> Nil)
    @__queue__.add(**opts, &block)
  end

  # Transport
  def send(message, **opts)
    queue(**opts) do |task|
      task.request_payload = message if task.responds_to?(:request_payload)
      transport.send(message)
    end
  end

  def send(message, **opts, &block : (Bytes, PlaceOS::Driver::Task) -> Nil)
    queue(**opts) do |task|
      task.request_payload = message if task.responds_to?(:request_payload)
      transport.send(message, task, &block)
    end
  end

  # Subscriptions and channels
  def subscribe(status, &callback : (Subscriptions::DirectSubscription, String) -> Nil) : Subscriptions::DirectSubscription
    raise "unsupported when running on the edge" if @__edge_driver__
    @__subscriptions__.not_nil!.subscribe(@__module_id__, status.to_s, &callback)
  end

  def publish(channel, message)
    if @__edge_driver__
      PlaceOS::Driver::Protocol.instance.request(channel, "publish", message, raw: true)
    else
      RedisStorage.with_redis &.publish("placeos/#{channel}", message.to_s)
    end
    message
  end

  def monitor(channel, &callback : (Subscriptions::ChannelSubscription, String) -> Nil) : Subscriptions::ChannelSubscription
    raise "unsupported when running on the edge" if @__edge_driver__
    @__subscriptions__.not_nil!.channel(channel.to_s, &callback)
  end

  # utilities
  def wake_device(mac_address, subnet = "255.255.255.255", port = 9)
    PlaceOS::Driver::Utilities::WakeOnLAN.wake_device(mac_address, subnet, port)
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

  IGNORE_KLASSES   = ["PlaceOS::Driver", "Reference", "Object", "Spec::ObjectExtensions", "Colorize::ObjectExtensions"]
  RESERVED_METHODS = {} of Nil => Nil
  {% RESERVED_METHODS["initialize"] = true %}
  {% RESERVED_METHODS["received"] = true %}
  {% RESERVED_METHODS["connected"] = true %}
  {% RESERVED_METHODS["disconnected"] = true %}
  {% RESERVED_METHODS["on_load"] = true %}
  {% RESERVED_METHODS["on_update"] = true %}
  {% RESERVED_METHODS["on_unload"] = true %}
  {% RESERVED_METHODS["websocket_headers"] = true %}
  {% RESERVED_METHODS["before_request"] = true %}
  {% RESERVED_METHODS["[]?"] = true %}
  {% RESERVED_METHODS["[]"] = true %}
  {% RESERVED_METHODS["[]="] = true %}
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
    {% methods = methods.reject(&.visibility.!=(:public)) %}
    {% methods = methods.reject &.accepts_block? %}
    # Filter out abstract methods
    {% methods = methods.reject &.body.stringify.empty? %}

    # :nodoc:
    class KlassExecutor
      # A class that handles executing every public method defined
      # NOTE:: currently doesn't handle multiple methods signatures (except block
      # and no block). Technically we could add the support however the JSON
      # parsing does not reliably pick the closest match and instead picks the
      # first or simplest match. So simpler to have a single method signature for
      # all public API methods
      def initialize(json : String)
        @lookup = Hash(String, JSON::Any).from_json(json)
        @exec = @lookup["__exec__"].as_s
      end

      @lookup : Hash(String, JSON::Any)
      @exec : String

      # :nodoc:
      EXECUTORS = {
        {% for method in methods %}
          {% index = 0 %}
          {% args = [] of Crystal::Macros::Arg %}
          {% for arg in method.args %}
            {% if !method.splat_index || index < method.splat_index %}
              {% args << arg %}
            {% end %}
            {% index = index + 1 %}
          {% end %}

          {{method.name.stringify}} => ->(json : JSON::Any, klass : {{@type.id}}) do
            {% if args.size > 0 %}

              # Support argument lists
              if json.raw.is_a?(Array)
                arg_names = { {{*args.map(&.name.stringify)}} }
                args = json.as_a

                raise "wrong number of arguments for '#{{{method.name.stringify}}}' (given #{args.size}, expected #{arg_names.size})" if args.size > arg_names.size

                hash = {} of String => JSON::Any
                json.as_a.each_with_index do |value, index|
                  hash[arg_names[index]] = value
                end

                json = hash
              end

              # Support named arguments
              tuple = {
                {% for arg in args %}
                  {% arg_name = arg.name.stringify %}

                  {% raise "#{@type}##{method.name} argument `#{arg.name}` is missing a type" if arg.restriction.is_a?(Nop) %}

                  {% if !arg.restriction.is_a?(Union) && arg.restriction.resolve < ::Enum %}
                    {% if arg.default_value.is_a?(Nop) %}
                      {{arg.name}}: ({{arg.restriction}}).parse(json[{{arg_name}}].as_s),
                    {% else %}
                      {{arg.name}}: json[{{arg_name}}]? != nil ? ({{arg.restriction}}).parse(json[{{arg_name}}].as_s) : {{arg.default_value}},
                    {% end %}
                  {% else %}
                    {% if arg.default_value.is_a?(Nop) %}
                      {{arg.name}}: ({{arg.restriction}}).from_json(json[{{arg_name}}].to_json),
                    {% else %}
                      {{arg.name}}: json[{{arg_name}}]? ? ({{arg.restriction}}).from_json(json[{{arg_name}}].to_json) : {{arg.default_value}},
                    {% end %}
                  {% end %}
                {% end %}
              }
              ret_val = klass.{{method.name}}(**tuple)
            {% else %}
              ret_val = klass.{{method.name}}
            {% end %}

            case ret_val
            when Array(::Log::Entry)
              ret_val.map(&.message).to_json
            when ::Log::Entry
              ret_val.message.to_json
            when Task
              ret_val
            when Enum
              ret_val.to_s.to_json
            when JSON::Serializable
              ret_val.to_json
            else
              ret_val = if ret_val.is_a?(::Future::Compute) || ret_val.is_a?(::Promise) || ret_val.is_a?(::PlaceOS::Driver::Task)
                ret_val.responds_to?(:get) ? ret_val.get : ret_val
              else
                ret_val
              end

              begin
                ret_val.try_to_json("null")
              rescue error
                klass.logger.info(exception: error) { "unable to convert result to json executing #{{{method.name.stringify}}} on #{klass.class}\n#{ret_val.inspect}" }
                "null"
              end
            end
          end,
        {% end %}
      } {% if methods.empty? %} of String => Nil {% end %}

      def execute(klass : {{@type.id}}) : Task | String
        json = @lookup[@exec]
        executor = EXECUTORS[@exec]?
        raise "execute requested for unknown method: #{@exec} on #{klass.class}" unless executor
        executor.call(json, klass)
      end

      # provide introspection into available functions
      @@functions : String?
      @@interface : String?

      def self.functions
        functions = @@interface
        return {functions, @@functions.not_nil!} if functions

        @@interface = iface = ({
          {% for method in methods %}
            {% index = 0 %}
            {% args = [] of Crystal::Macros::Arg %}
            {% for arg in method.args %}
              {% if !method.splat_index || index < method.splat_index %}
                {% args << arg %}
              {% end %}
              {% index = index + 1 %}
            {% end %}

            {{method.name.stringify}} => {
              {% for arg in args %}
                {{arg.name.stringify}} => PlaceOS::Driver::Settings.introspect({{arg.restriction.resolve}}).
                  {% if arg.default_value.is_a?(Nop) %}
                    merge({ title: {{arg.restriction.resolve.stringify}} }),
                  {% else %}
                    merge({ title: {{arg.restriction.resolve.stringify}}, default: {{arg.default_value}} }),
                  {% end %}
              {% end %}
            }{% if args.size == 0 %} of String => Array(String) {% end %},
          {% end %}
        }{% if methods.size == 0 %} of Nil => Nil {% end %}).to_json

        @@functions = funcs = ({
          {% for method in methods %}
            {% index = 0 %}
            {% args = [] of Crystal::Macros::Arg %}
            {% for arg in method.args %}
              {% if !method.splat_index || index < method.splat_index %}
                {% args << arg %}
              {% end %}
              {% index = index + 1 %}
            {% end %}

            {{method.name.stringify}} => {
              {% for arg in args %}
                {{arg.name.stringify}} => {
                  {{arg.restriction.stringify}},
                  {% unless arg.default_value.is_a?(Nop) %}
                    {{arg.default_value}},
                  {% end %}
                },
              {% end %}
            }{% if args.size == 0 %} of String => Array(String) {% end %},
          {% end %}
        }{% if methods.size == 0 %} of Nil => Nil {% end %}).to_json

        {iface, funcs}
      end

      class_getter security : String do
        Hash(String, Array(String)).new { |h, k| h[k] = [] of String }.tap { |sec|
          {% for method in methods.select { |m| !!m.annotation(Security) } %}
            level = {{method.annotation(Security)[0]}}.as(::PlaceOS::Driver::Level).to_s.downcase
            sec[level] << {{ method.name.stringify }}
          {% end %}
        }.to_json
      end

      class_getter metadata : String do
        implements = {{@type.ancestors.map(&.stringify.split("(")[0])}}.reject { |obj| IGNORE_KLASSES.includes?(obj) }
        iface, funcs = self.functions

        %({
          "interface": #{iface},
          "functions": #{funcs},
          "implements": #{implements.to_json},
          "requirements": #{Utilities::Discovery.requirements.to_json},
          "security": #{self.security}
        }).gsub(/\s/, "")
      end

      # unlike metadata, the schema is not required for runtime
      def self.metadata_with_schema
        meta = metadata.rchop
        schema = PlaceOS::Driver::Settings.get { generate_json_schema }
        %(#{meta},"json_schema":#{schema}})
      end

      # this is what will be stored in redis for cross driver comms
      # we need to use the command line to obtain this as the data is not available
      # at this point in compilation and the JSON schema is useful for logic drivers
      class_getter driver_interface : String do
        if PlaceOS::Driver.include_json_schema_in_interface
          current_process = Process.executable_path.not_nil!

          # ensure the data here is correct, raise error if not
          iface_data = ""
          begin
            iface_data = `#{current_process} -m`.strip
            JSON.parse(iface_data).to_json
          rescue error
            Log.error(exception: error) { "failed to extract JSON schema for interface\n#{iface_data.inspect}" }
            # fallback to interface without schema
            {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.metadata
          end
        else
          {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.metadata
        end
      end
    end
  end
end

require "./placeos-driver/constants"
require "./placeos-driver/core_ext"
require "./placeos-driver/driver_manager"
require "./placeos-driver/driver_model"
require "./placeos-driver/exception"
require "./placeos-driver/logger_io"
require "./placeos-driver/process_manager"
require "./placeos-driver/protocol"
require "./placeos-driver/queue"
require "./placeos-driver/settings"
require "./placeos-driver/status"
require "./placeos-driver/storage"
require "./placeos-driver/subscriptions"
require "./placeos-driver/task"
require "./placeos-driver/transport"

require "./placeos-driver/storage/edge-storage"
require "./placeos-driver/proxy/*"
require "./placeos-driver/subscriptions/*"
require "./placeos-driver/transport/*"
require "./placeos-driver/utilities/*"

macro finished
  # Launch the process manager by default, this can be overriten for testing
  if PlaceOS::Startup.exec_process_manager
    process = PlaceOS::Driver::ProcessManager.new(edge_driver: PlaceOS::Startup.is_edge_driver)

    # Detect ctr-c to shutdown gracefully
    Signal::INT.trap do |signal|
      puts " > terminating gracefully"
      spawn(same_thread: true) { process.terminate }
      signal.ignore
    end

    process.terminated.receive?
  end

  # This is here so we can be certain that settings macros have expanded
  # metadata needed to be compiled after process manager
  if PlaceOS::Startup.print_defaults
    defaults = PlaceOS::Driver::Utilities::Discovery.defaults
    puts PlaceOS::Startup.print_meta ? %(#{defaults.rchop},#{ {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.metadata.lchop }) : defaults
  elsif PlaceOS::Startup.print_meta
    puts {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.metadata_with_schema
  end
end
