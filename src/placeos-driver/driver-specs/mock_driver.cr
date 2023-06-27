require "json-schema"
require "log"
require "../core_ext"
require "../storage"
require "../task"
require "./status_helper"
require "../settings"

class DriverSpecs; end

abstract class DriverSpecs::MockDriver
  # :nodoc:
  Log = ::Log.for("mock")

  # :nodoc:
  abstract class BaseExecutor
    def initialize(json : String)
      @lookup = Hash(String, JSON::Any).from_json(json)
      @exec = @lookup["__exec__"].as_s
    end

    @lookup : Hash(String, JSON::Any)
    @exec : String

    abstract def execute(klass : MockDriver) : String
  end

  # :nodoc:
  def initialize(@module_id : String)
    @__storage__ = PlaceOS::Driver::RedisStorage.new(module_id)

    __init__
  end

  # :nodoc:
  abstract def __init__ : Nil

  # :nodoc:
  abstract def __executor(json : String) : BaseExecutor

  # :nodoc:
  def on_load; end

  # Grab the status storage for a mock module
  #
  # i.e. `system("Module_2")`
  def system(module_id : String | Symbol) : DriverSpecs::StatusHelper
    mod_name, match, index = module_id.to_s.rpartition('_')
    mod_name, index = if match.empty?
                        {module_id, 1}
                      else
                        {mod_name, index.to_i}
                      end
    DriverSpecs::StatusHelper.new("mod-#{mod_name}/#{index}")
  end

  # proxies `Log` so you can use the logger in the same way as drivers
  def logger
    ::DriverSpecs::MockDriver::Log
  end

  # Expose a status key to other mock drivers and the driver we're testing
  def []=(key, value)
    key = key.to_s
    current_value = @__storage__[key]?
    json_data = value.is_a?(::Enum) ? value.to_s.to_json : value.to_json
    if json_data != current_value
      @__storage__[key] = json_data
      logger.debug { "status updated: #{key} = #{json_data}" }
    else
      logger.debug { "no change for: #{key} = #{json_data}" }
    end
    value
  end

  # returns the current value of a status value and raises if it does not exist
  def [](key)
    JSON.parse @__storage__[key]
  end

  # returns the current value of a status value and nil if it does not exist
  def []?(key)
    if json_data = @__storage__[key]?
      JSON.parse json_data
    end
  end

  # pushes a change notification for the key specified, even though it hasn't changed
  def signal_status(key)
    spawn(same_thread: true) { @__storage__.signal_status(key) }
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

  # Remote execution helpers
  macro inherited
    macro finished
      {% if !@type.abstract? %}
        __build_helpers__
      {% end %}
    end
  end

  # :nodoc:
  IGNORE_KLASSES = ["DriverSpecs", "PlaceOS::Driver", "Reference", "Object", "Spec::ObjectExtensions", "Colorize::ObjectExtensions"]

  # :nodoc:
  RESERVED_METHODS = {} of Nil => Nil
  {% RESERVED_METHODS["logger"] = true %}
  {% RESERVED_METHODS["system"] = true %}
  {% RESERVED_METHODS["__init__"] = true %}
  {% RESERVED_METHODS["on_load"] = true %}
  {% RESERVED_METHODS["__executor"] = true %}
  {% RESERVED_METHODS["on_unload"] = true %}
  {% RESERVED_METHODS["[]?"] = true %}
  {% RESERVED_METHODS["[]"] = true %}
  {% RESERVED_METHODS["[]="] = true %}
  {% RESERVED_METHODS["send"] = true %}
  {% RESERVED_METHODS["signal_status"] = true %}

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

    # :nodoc:
    class KlassExecutor < BaseExecutor
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

                  {% if !arg.restriction.is_a?(Union) && !arg.restriction.is_a?(Nop) && arg.restriction.resolve < ::Enum %}
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
      }

      def execute(klass : ::DriverSpecs::MockDriver) : String
        klass = klass.as({{@type.id}})
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

      class_getter metadata : String do
        implements = {{@type.ancestors.map(&.stringify.split("(")[0])}}.reject { |obj| IGNORE_KLASSES.includes?(obj) }
        iface, funcs = self.functions

        # TODO:: remove functions eventually (once fully deprecated in driver model)
        details = %({
          "interface": #{iface},
          "functions": #{funcs},
          "implements": #{implements.to_json},
          "requirements": {},
          "security": {}
        }).gsub(/\s/, "")

        @@metadata = details
      end
    end

    def __init__ : Nil
      @__storage__.clear
      PlaceOS::Driver::RedisStorage.with_redis do |redis|
        redis.set("interface/#{@module_id}", KlassExecutor.metadata)
      end
      on_load
    end

    def __executor(json : String) : BaseExecutor
      KlassExecutor.new(json)
    end
  end
end
