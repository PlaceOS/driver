require "json"

abstract class PlaceOS::Driver
  # provides a discoverable interface for LLMs
  module Interface::ChatFunctions
    # overall description of what this driver implements
    abstract def capabilities : String

    # function name => function description
    abstract def function_descriptions : Hash(String, String)

    # returns function name => [function description, {param name => JSON Schema}]
    def function_schemas : Hash(String, Tuple(String, Hash(String, JSON::Any)))
      # function name => {param name => JSON Schema}
      interface = Hash(String, Hash(String, JSON::Any)).from_json(self.class.driver_interface)

      output = Hash(String, Tuple(String, Hash(String, JSON::Any))).new

      function_descriptions.each do |function_name, function_description|
        if schema = interface[function_name]?
          output[function_name] = {function_description, schema}
        else
          logger.warn { "described function not found: #{function_name}" }
        end
      end

      output
    end
  end
end
