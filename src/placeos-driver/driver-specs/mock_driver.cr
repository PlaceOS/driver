require "log"
require "../core_ext"
require "../storage"
require "../status"
require "./status_helper"

class DriverSpecs; end

abstract class DriverSpecs::MockDriver
  Log = ::Log.for("mock")

  abstract class BaseExecutor
    def initialize(json : String)
      @lookup = Hash(String, JSON::Any).from_json(json)
      @exec = @lookup["__exec__"].as_s
    end

    @lookup : Hash(String, JSON::Any)
    @exec : String

    abstract def execute(klass : MockDriver) : String
  end

  def initialize(@module_id : String)
    @__storage__ = PlaceOS::Driver::RedisStorage.new(module_id)
    @__status__ = PlaceOS::Driver::Status.new

    __init__
  end

  abstract def __init__ : Nil
  abstract def __executor(json : String) : BaseExecutor

  def on_load; end

  # Grab the storage for "Module_2"
  def system(module_id : String | Symbol) : DriverSpecs::StatusHelper
    mod_name, match, index = module_id.to_s.rpartition('_')
    mod_name, index = if match.empty?
                        {module_id, 1}
                      else
                        {mod_name, index.to_i}
                      end
    DriverSpecs::StatusHelper.new("mod-#{mod_name}/#{index}")
  end

  def logger
    ::DriverSpecs::MockDriver::Log
  end

  def []=(key, value)
    key = key.to_s
    json_data, did_change = @__status__.set_json(key, value)
    if did_change
      # using spawn so execution flow isn't interrupted.
      # ensures that setting a key and then reading it back as the next
      # operation will always result in the expected value
      @__storage__[key] = json_data
      logger.debug { "status updated: #{key} = #{value}" }
    else
      # We still update the state in mocks as this could have been modified outside
      @__storage__[key] = json_data
      logger.debug { "no change for: #{key} = #{value}" }
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

  # Remote execution helpers
  macro inherited
    macro finished
      {% if !@type.abstract? %}
        __build_helpers__
      {% end %}
    end
  end

  IGNORE_KLASSES   = ["DriverSpecs", "PlaceOS::Driver", "Reference", "Object", "Spec::ObjectExtensions", "Colorize::ObjectExtensions"]
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

  macro __build_helpers__
    {% methods = @type.methods %}
    {% klasses = @type.ancestors.reject { |a| IGNORE_KLASSES.includes?(a.stringify) } %}
    # {{klasses.map &.stringify}} <- in case we need to filter out more classes
    {% klasses.map { |a| methods = methods + a.methods } %}
    {% methods = methods.reject { |method| RESERVED_METHODS[method.name.stringify] } %}
    {% methods = methods.reject { |method| method.visibility != :public } %}
    {% methods = methods.reject &.accepts_block? %}
    # Filter out abstract methods
    {% methods = methods.reject &.body.stringify.empty? %}

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
              ret_val = ret_val.responds_to?(:get) ? ret_val.get : ret_val
              begin
                ret_val.try_to_json("null")
              rescue error
                klass.logger.info(exception: error) { "unable to convert result to json executing #{{{method.name.stringify}}} on #{klass.class}" }
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
      def self.functions : String
        functions = @@functions
        return functions if functions

        @@functions = funcs = {
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
                {{arg.name.stringify}} => [
                  {% if !arg.restriction.is_a?(Union) && !arg.restriction.is_a?(Nop) && arg.restriction.resolve < ::Enum %}
                    "String",
                    {% if !arg.default_value.is_a?(Nop) %}
                      {{arg.default_value}}.to_s
                    {% end %}
                  {% else %}
                    {{arg.restriction.stringify}},
                    {% if !arg.default_value.is_a?(Nop) %}
                      {{arg.default_value}}
                    {% end %}
                  {% end %}
                ],
              {% end %}
            }{% if args.size == 0 %} of String => Array(String){% end %},
          {% end %}
        }.to_json
        funcs
      end

      @@metadata : String?
      def self.metadata : String
        metadata = @@metadata
        return metadata if metadata

        implements = {{@type.ancestors.map(&.stringify.split("(")[0])}}.reject { |obj| IGNORE_KLASSES.includes?(obj) }
        details = %({
          "functions": #{self.functions},
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
