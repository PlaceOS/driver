require "json-schema"
require "option_parser"
require "yaml"

# :nodoc:
class PlaceOS::Startup
  class_property exec_process_manager : Bool = false
  class_property is_edge_driver : Bool = false
  class_property print_meta : Bool = false
  class_property print_defaults : Bool = false
  class_property suppress_logs : Bool = false
  class_property socket : String? = nil
end

# Command line options
OptionParser.parse(ARGV.dup) do |parser|
  parser.banner = "Usage: #{PROGRAM_NAME} [arguments]"

  parser.on("-m", "--metadata", "output driver metadata") do
    PlaceOS::Startup.print_meta = true
    PlaceOS::Startup.suppress_logs = true
  end

  parser.on("-d", "--defaults", "output driver defaults") do
    PlaceOS::Startup.print_defaults = true
    PlaceOS::Startup.suppress_logs = true
  end

  parser.on("-s SOCKET", "--socket=SOCKET", "protocol server socket") do |socket|
    PlaceOS::Startup.socket = socket.strip
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

require "./placeos-driver/logger"
require "./placeos-driver/stats"

# This is base class for all PlaceOS drivers.
# It implements a standardised interface by introspecting the driver code you write.
abstract class PlaceOS::Driver
  # :nodoc:
  class_property include_json_schema_in_interface : Bool = true

  module Proxy
  end

  module Utilities
  end

  # applies a security level to a driver function
  #
  # ```
  # @[Security(Level::Administrator)]
  # def my_driver_function
  # end
  # ```
  annotation Security
  end

  # the level of security a user must have to execute a function
  enum Level
    Support
    Administrator
  end

  # :nodoc:
  def initialize(
    @__module_id__ : String,
    @__setting__ : Settings,
    @__queue__ : Queue,
    @__transport__ : Transport,
    @__logger__ : PlaceOS::Driver::Log,
    @__schedule__ = Proxy::Scheduler.new,
    @__subscriptions__ = Proxy::Subscriptions.new,
    @__driver_model__ = DriverModel.from_json(%({"udp":false,"tls":false,"makebreak":false,"settings":{},"role":1})),
    @__edge_driver__ : Bool = false,
  )
    metadata = {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.driver_interface
    metadata = %(#{metadata[0..-2]},"notes":#{@__driver_model__.notes.to_json}})
    if @__edge_driver__
      @__storage__ = EdgeStorage.new(@__module_id__)
      @__storage__.clear
      PlaceOS::Driver::Protocol.instance.request("interface/#{@__module_id__}", :set, metadata, raw: true)
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

  # :nodoc:
  # Access to the various components
  HELPERS = %w(transport logger queue setting schedule)
  {% for name in HELPERS %}
    def {{name.id}}
      @__{{name.id}}__
    end
  {% end %}

  # provides access to the modules subscriptions tracker
  def subscriptions : ::PlaceOS::Driver::Proxy::Subscriptions
    raise "unsupported when running on the edge" if @__edge_driver__
    @__subscriptions__.not_nil!
  end

  # the modules database configuration
  def config : ::PlaceOS::Driver::DriverModel
    @__driver_model__
  end

  # :nodoc:
  def config=(data : ::PlaceOS::Driver::DriverModel)
    @__system__ = nil
    @__driver_model__ = data
  end

  # the id of the currently running module
  def module_id : String
    @__module_id__
  end

  # :nodoc:
  protected def terminated?
    @__queue__.terminated
  end

  # was the current function executed directly by a user?
  def invoked_by_user_id
    Fiber.current.name
  end

  # Expose a status key to other drivers and frontends #}
  # allowing them to bind to value updates
  def []=(key, value)
    key = key.to_s
    # TODO:: we should add a cache if values are longer than a certain value and
    # store a SHA265 of the JSON value to avoid the transfer of larger values
    # (without storing them locally)
    current_value = @__storage__[key]?
    json_data = value.is_a?(::Enum) ? value.to_s.to_json : value.to_json
    if json_data != current_value
      @__storage__[key] = json_data
      @__logger__.debug { "status updated: #{key} = #{json_data}" }
    else
      @__logger__.debug { "no change for: #{key} = #{json_data}" }
    end
    value
  end

  # returns the current value of a status value and raises if it does not exist
  def [](key) : JSON::Any
    JSON.parse @__storage__[key]
  end

  # returns the current value of a status value and nil if it does not exist
  def []?(key) : JSON::Any?
    if json_data = @__storage__[key]?
      JSON.parse json_data
    end
  end

  # reads a status key and deserialises the value into the class provided.
  #
  # It raises if the class does not exist.
  macro status(klass, key)
    {{klass}}.from_json(@__storage__[{{key}}.to_s])
  end

  # reads a status key and deserialises the value into the class provided.
  #
  # It returns `nil` if the key doesn't exist
  macro status?(klass, key)
    %value = @__storage__[{{key}}.to_s]?
    {{klass}}.from_json(%value) if %value
  end

  # pushes a change notification for the key specified, even though it hasn't changed
  def signal_status(key)
    spawn(same_thread: true) { @__storage__.signal_status(key) }
  end

  # provides access to the details of the system the logic driver is running in.
  #
  # NOTE:: this only works for logic drivers as other drivers can be in multiple systems.
  def system : Proxy::System
    sys = @__system__
    return sys if sys

    system_model = @__driver_model__.control_system
    raise "not directly associated with a system" unless system_model
    @__system__ = Proxy::System.new(system_model, @__module_id__, @__logger__, @__subscriptions__.not_nil!)
  end

  # provides access to the details of a remote system, if you have the ID of the system.
  def system(id : String) : Proxy::System
    Proxy::System.new(id, @__module_id__, @__logger__, @__subscriptions__.not_nil!)
  end

  # reads the provided class type out of the settings provided at the provided key.
  #
  # i.e. given a setting: `values: [1, 2, 3]`
  #
  # you can extract index 2 number using: `setting(Int64, :values, 2)`
  macro setting(klass, *types)
    @__setting__.get { setting({{klass}}, {{types.splat}}) }
  end

  # reads the provided class type out of the settings provided at the provided key.
  #
  # i.e. given a setting: `keys: {"public": "123456"}`
  #
  # you can extract the public key using: `setting?(String, :keys, :public)`
  macro setting?(klass, *types)
    @__setting__.get { setting?({{klass}}, {{types.splat}}) }
  end

  # if you would like to save an updated value to settings so it survives restarts
  def define_setting(name, value)
    PlaceOS::Driver::Protocol.instance.request(@__module_id__, :setting, {name, value})
  end

  # Queue a task that intends to use the transport layer
  #
  # primarily useful where a device can only perform a single function at a time and ordering is important
  #
  # i.e power-on, switch-input, set-volume
  #
  # however you typically won't need to use this function directly. See #send
  #
  # `opts` options include:
  #
  # * priority: an `Int` between 0 and 100 where 0 is highest priority and 100 is the lowest
  #
  # * timeout: a `Time::Span` indicating the maximum time the task should wait for a response
  #
  # * retries: how many attempts should be made to successfully complete a task
  #
  # * wait: `Bool` should we wait for a response (defaults to true)
  #
  # * name: `String` of the command, if there is already a command with the same name in the queue, it will be replaced with this.
  #
  # * delay: `Time::Span` how long to wait after executing this command before executing the next
  #
  # * clear_queue: `Bool` after executing task, clear all the remaining tasks in the queue
  def queue(**opts, &block : Task -> Nil)
    @__queue__.add(**opts, &block)
  end

  # queues a message to be sent to the transport layer.
  #
  # see #queue for available options
  def send(message, **opts)
    queue(**opts) do |task|
      task.request_payload = message if task.responds_to?(:request_payload)
      transport.send(message)
    end
  end

  # queues a message to be sent to the transport layer.
  #
  # the provided block is used to process responses while this task is active
  def send(message, **opts, &block : (Bytes, PlaceOS::Driver::Task) -> Nil)
    queue(**opts) do |task|
      task.request_payload = message if task.responds_to?(:request_payload)
      transport.send(message, task, &block)
    end
  end

  # Subscribe to a local status value
  #
  # `subscription = subscribe(:my_status) { |subscription, string_value| ... }`
  #
  # use `subscriptions.unsubscribe(subscription)` to unsubscribe
  def subscribe(status, &callback : (Subscriptions::DirectSubscription, String) -> Nil) : Subscriptions::DirectSubscription
    raise "unsupported when running on the edge" if @__edge_driver__
    @__subscriptions__.not_nil!.subscribe(@__module_id__, status.to_s, &callback)
  end

  # publishes a message to a channel on redis, available to any drivers monitoring for these events
  #
  # `publish("my_service/channel", "payload contents")`
  def publish(channel, message)
    message = message.to_s
    if @__edge_driver__
      PlaceOS::Driver::Protocol.instance.request(channel, :publish, message, raw: true)
    else
      RedisStorage.with_redis &.publish("placeos/#{channel}", message)
    end
    @__logger__.debug { "published: #{channel} -> #{message}" }
    message
  end

  # monitor for messages being published on redis
  #
  # `subscription = monitor("my_service/channel") { |subscription, string_value| ... }`
  #
  # use `subscriptions.unsubscribe(subscription)` to unsubscribe
  def monitor(channel, &callback : (Subscriptions::ChannelSubscription, String) -> Nil) : Subscriptions::ChannelSubscription
    raise "unsupported when running on the edge" if @__edge_driver__
    @__subscriptions__.not_nil!.channel(channel.to_s, &callback)
  end

  # sends a wake-on-lan message the specified mac_address, specify a subnet for directed WOL
  def wake_device(mac_address, subnet = "255.255.255.255", port = 9)
    PlaceOS::Driver::Utilities::WakeOnLAN.wake_device(mac_address, subnet, port)
  end

  # used to provide feedback in backoffice about the state of a driver
  #
  # online: true == Green, online: false == Red in backoffice
  #
  # setting `status_only: false` will set the queue online state.
  #
  # when offline, this means the queue will ignore all unnamed tasks to avoid memory leaks.
  def set_connected_state(online, status_only = true)
    online = !!online
    if status_only
      @__queue__.set_connected(online)
    else
      @__queue__.online = online
    end
  end

  # forces a disconnect of the network transport, which will promptly reconnect
  def disconnect
    @__transport__.disconnect
  end

  # :nodoc:
  # Keep track of loaded driver classes. Should only be one.
  CONCRETE_DRIVERS = {} of Nil => Nil

  # Remote execution helpers
  macro inherited
    macro finished
      {% if !@type.abstract? %}
        __build_helpers__
        {% CONCRETE_DRIVERS[@type] = [@type.methods, (@type.name.id.stringify + "::KlassExecutor").id] %}
        __build_apply_bindings__
        ::PlaceOS::Driver._rescue_from_inject_functions_
      {% end %}
    end
  end

  # :nodoc:
  IGNORE_KLASSES = ["PlaceOS::Driver", "Reference", "Object", "Spec::ObjectExtensions", "Colorize::ObjectExtensions"]

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
  {% RESERVED_METHODS["__handle_rescue_from__"] = true %}
  {% for name in HELPERS %}
    {% RESERVED_METHODS[name.id.stringify] = true %}
  {% end %}

  # :nodoc:
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

    class_getter driver_interface : String do
      JSON.parse(KlassExecutor.driver_interface)["interface"].to_json
    end

    # :nodoc:
    struct KlassExecutor
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
                arg_names = { {{args.map(&.name.stringify).splat}} }
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

            # ensures false is returned
            ret_val = ret_val.is_a?(Bool) ? ret_val : (ret_val || nil)
            ::PlaceOS::Driver::DriverManager.process_result(klass, {{method.name.stringify}}, ret_val)
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
                {{arg.name.stringify}} => JSON::Schema.introspect({{arg.restriction.resolve}}).
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

        # TODO:: remove functions eventually (once fully deprecated in driver model)
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
          current_process = ENV["CURRENT_DRIVER_PATH"]? || Process.executable_path.not_nil!

          # ensure the data here is correct, raise error if not
          iface_data = ""
          begin
            stdout = IO::Memory.new
            success = Process.new(current_process, {"-m"}, output: stdout).wait.success?
            raise "process execution failed" unless success
            iface_data = stdout.to_s.strip
            JSON.parse(iface_data).to_json
          rescue error
            Log.error(exception: error) { "failed to extract JSON schema from #{current_process} for interface\n#{iface_data.inspect}" }
            # fallback to interface without schema
            {{::PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.metadata
          end
        else
          {{::PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.metadata
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
require "./placeos-driver/storage"
require "./placeos-driver/subscriptions"
require "./placeos-driver/task"
require "./placeos-driver/transport"

require "./placeos-driver/storage/edge-storage"
require "./placeos-driver/proxy/*"
require "./placeos-driver/subscriptions/*"
require "./placeos-driver/transport/*"
require "./placeos-driver/utilities/*"

require "socket"

macro finished
  # Launch the process manager by default, this can be overriten for testing
  if PlaceOS::Startup.exec_process_manager
    if socket = PlaceOS::Startup.socket
      sock = UNIXSocket.new(socket)
      protocol = PlaceOS::Driver::Protocol.new_instance(input: sock, output: sock, edge_driver: PlaceOS::Startup.is_edge_driver)
    else
      protocol = PlaceOS::Driver::Protocol.new_instance(edge_driver: PlaceOS::Startup.is_edge_driver)
    end

    # Detect ctr-c to shutdown gracefully
    Signal::INT.trap do |signal|
      puts " > terminating gracefully"
      spawn(same_thread: true) { protocol.process_manager.terminate }
      signal.ignore
    end

    protocol.process_manager.as(PlaceOS::Driver::ProcessManager).terminated.receive?
  end

  # If we are launching for the purposes of printing messages then we want to
  # disable outputting of log messages
  if PlaceOS::Startup.print_meta || PlaceOS::Startup.print_defaults
    ::Log.setup(:fatal)
    ::Log.builder.clear
  end

  # This is here so we can be certain that settings macros have expanded
  # metadata needed to be compiled after process manager
  if PlaceOS::Startup.print_defaults
    defaults = PlaceOS::Driver::Utilities::Discovery.defaults
    puts PlaceOS::Startup.print_meta ? %(#{defaults.rchop},#{ {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.metadata.lchop }) : defaults
    exit 0
  elsif PlaceOS::Startup.print_meta
    puts {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.metadata_with_schema
    exit 0
  end

  abstract class PlaceOS::Driver
    # :nodoc:
    # inject the rescue_from handlers
    def __handle_rescue_from__(instance, method_name, error)
      ret_val = case error
      {% for exception, details in ::PlaceOS::Driver::RESCUE_FROM %}
      when {{exception.id}} then {{details[0]}}(error)
      {% end %}
      else
        raise error
      end

      ::PlaceOS::Driver::DriverManager.process_result(instance, method_name, ret_val)
    end
  end

  class PlaceOS::Driver::DriverManager
    define_run_execute
  end
end
