require "json"

class EngineDriver::Proxy::Driver
  @@id = 0_u64

  def initialize(
    @module_name : String,
    @index : Int32,
    @module_id : String,
    @system : EngineDriver::Proxy::System,
    @metadata : EngineDriver::DriverModel::Metadata
  )
    @status = EngineDriver::Storage.new(@module_id)
  end

  def [](status)
    @status.fetch_json(status)
  end

  def []?(status)
    @status.fetch_json?(status)
  end

  def implements?(interface) : Bool
    @metadata.implements.includes?(interface.to_s) || !@metadata.functions[function.to_s].nil?
  end

  # TODO:: don't raise errors directly.
  # Ensure they are logged and raise if the response is requested
  macro method_missing(call)
    function_name = {{call.name.id.stringify}}

    function = @metadata.functions[function_name]?
    if function
      # obtain the arguments provided
      arguments = {{call.args}}
      {% if call.named_args.size > 0 %}
        named_args = {
          {% for arg, index in call.named_args %}
            {{arg.name.stringify.id}}: {{arg.value}},
          {% end %}
        }
      {% else %}
        named_args = {} of String => String
      {% end %}

      # Check if there is an argument mismatch }
      num_args = arguments.size + named_args.size
      funcsize = function.size
      if num_args > funcsize
        raise "wrong number of arguments for '#{function_name}' (given #{num_args}, expected #{funcsize})"
      elsif num_args < funcsize
        defaults = 0

        # check for defaults if there are not enough arguments
        function.each_value do |arg_details|
          defaults += 1 if arg_details.size > 1
        end

        minargs = funcsize - defaults
        raise "wrong number of arguments for '#{function_name}' (given #{num_args}, expected #{minargs}..#{funcsize})" if num_args < minargs
      end

      # Build the request payload
      args = {} of String => String
      request = {
        "__exec__" => function_name,
        function_name => args
      }

      # Apply the arguments
      index = 0
      function.each_key do |arg_name|
        value = named_args[arg_name]?
        if value.nil?
          value = args[index]?
          index += 1
        end

        args[arg_name] = value
      end

      # Create the request
      @@id += 1
      request = EngineDriver::Protocol::Request.new(
        @@id.to_s,
        "exec",
        request.to_json
      )

      # TODO:: need to create a promise where we can obtain the result
      EngineDriver::Protocol.instance.send(request)
    else
      raise "undefined method '#{function_name}' for #{@module_name}_#{@index} (#{@module_id})"
    end
  end
end
