# https://github.com/Sija/retriable.cr#kernel-extension
require "retriable/core_ext/kernel"

abstract class EngineDriver
  def initialize(@queue : EngineDriver::Queue, @transport : EngineDriver::TransportTCP)
  end

  property :queue, :transport

  macro inherited
    macro finished
        __build_helpers__
    end
  end

  RESERVED_METHODS = {} of Nil => Nil
  {% RESERVED_METHODS["received"] = true %}

  macro __build_helpers__
    {% methods = @type.methods %}
    {% methods = methods.reject { |method| RESERVED_METHODS[method.name.stringify] } %}
    {% methods = methods.reject { |method| method.visibility != :public } %}

    # Build a class that represents each method
    {% for method in methods %}
      class Method{{method.name.stringify.camelcase.id}}
        JSON.mapping(
          {% if method.args.size == 0 %}
             {} of String => String
          {% else %}
             {% for arg in method.args %}
                {% if !arg.restriction %}
                  "Public method '{{@type.id}}.{{method.name}}' has no type specified for argument '{{arg.name}}'"
                {% else %}
                  {{arg.name}}: {{arg.restriction}}
                {% end %}
            {% end %}
          {% end %}
        )
      end
    {% end %}

    # A class that handles every method
    class KlassExecutor
      JSON.mapping(
        ___exec: String,
        {% for method in methods %}
            {{method.name}}: Method{{method.name.stringify.camelcase.id}}?,
        {% end %}
      )

      # Once serialised, we want to execute the request on the class
      def execute(klass : {{@type.id}})
        case self.___exec
        {% for method in methods %}
          when {{method.name.stringify}}
            {% if method.args.size == 0 %}
              return klass.{{method.name}}
            {% else %}
              obj = self.{{method.name}}.not_nil!
              args = {
                {% for arg in method.args %}
                  {{arg.name}}: obj.{{arg.name}}
                {% end %}
              }
              return klass.{{method.name}} **args
            {% end %}
        {% end %}
        end

        raise "unknown method"
      end
    end

    # provide introspection into available functions
    @@functions : String?
    def self.__functions__
      functions = @@functions
      return functions if functions
        list = %[{
        {% for method in methods %}
          {{method.name.stringify}}: {
            {% for arg in method.args %}
              {{arg.name.stringify}}: {{arg.restriction.stringify}}
            {% end %}
          },
        {% end %} ]
      @@functions = list.gsub(/\s/, "")[0..-2] + '}'
    end
  end
end

require "./engine-driver/*"
require "./engine-driver/**"
