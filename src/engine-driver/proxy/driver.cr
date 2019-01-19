require "json"

class EngineDriver::Proxy::Driver
  def initialize(@module_id : String, @system : EngineDriver::Proxy::System, @metadata : EngineDriver::DriverModel::Metadata)
    @status = EngineDriver::Storage.new(@module_id)
  end

  def [](status)
    @status.fetch_json(status)
  end

  def []?(status)
    @status.fetch_json?(status)
  end

  macro method_missing(call)
    print "Got ", {{call.name.id.stringify}}, " with ", {{call.args.size}}, " arguments", '\n'
    function_name = {{call.name.id.stringify}}

    request = {
      "__exec__": "add",
      "add": {
        "a": 1,
        "b": 2
      }
    }
  end
end
