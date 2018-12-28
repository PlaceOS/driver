abstract class EngineDriver
  macro inherited
    macro finished
        __build_helpers__
    end
  end

  macro __build_helpers__
    # Build a class that represents each method
    {% for method in @type.methods %}
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
        {% for method in @type.methods %}
            {{method.name}}: Method{{method.name.stringify.camelcase.id}}?,
        {% end %}
      )

      # Once serialised, we want to execute the request on the class
      def execute(klass : {{@type.id}})
        case self.___exec
        {% for method in @type.methods %}
          {% if method.visibility == :public %}
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
        {% for method in @type.methods %}
          {% if method.visibility == :public %}
            {{method.name.stringify}}: {
              {% for arg in method.args %}
                {{arg.name.stringify}}: {{arg.restriction.stringify}}
              {% end %}
            },
          {% end %}
        {% end %} ]
      @@functions = list.gsub(/\s/, "")[0..-2] + '}'
    end
  end
end

require "./engine-driver/*"
