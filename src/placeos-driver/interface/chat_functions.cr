require "json"

abstract class PlaceOS::Driver
  # provides a discoverable interface for LLMs
  module Interface::ChatFunctions
    annotation Description
    end

    macro build_function_descriptions
      def function_descriptions
        {
          {% for method in @type.methods %}
            {% if method.annotation(Description) %}
              {{method.name}}: {{method.annotation(Description)[0]}},
            {% end %}
          {% end %}
        }
      end
    end

    macro included
      macro finished
        build_function_descriptions
      end
    end

    # overall description of what this driver implements
    abstract def capabilities : String

    # returns function name => {param name => JSON Schema}
    def function_schemas : Hash(String, Hash(String, JSON::Any))
      # function name => {param name => JSON Schema}
      interface = Hash(String, Hash(String, JSON::Any)).from_json(self.class.driver_interface)
      output = Hash(String, Hash(String, JSON::Any)).new

      # filter the interface to those functions with descriptions
      # as these are the only ones that the LLM should use
      function_descriptions.each do |function_name, function_description|
        name = function_name.to_s
        if schema = interface[name]?
          output[name] = schema
        else
          logger.warn { "described function not found: #{function_name}" }
        end
      end

      output
    end
  end
end
