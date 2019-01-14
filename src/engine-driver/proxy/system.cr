
class EngineDriver::Proxy::System
  def initialize(@system_id : String)
    @system = EngineDriver::Storage.new(@system_id, "system")
  end

  def [](module_id)
    get(module_id)
  end

  # TODO:: driver proxy
  def get(module_name, index = nil)
    module_name, index = get_parts(module_name) unless index

  end

  # Checks for the existence of a particular module
  def exists?(module_name, index = nil) : Bool
    module_name, index = get_parts(module_name) unless index
    !@system["#{module_name}\x02#{index}"]?.nil?
  end

  # Returns a list of all the module names in the system
  def modules
    @system.keys.map { |key| key.split("\x02")[0] }.uniq
  end

  # Grabs the number of a particular device type
  def count(module_name)
    module_name = module_name.to_s
    @system.keys.map { |key| key.split("\x02")[0] }.reject { |key| key != module_name }.size
  end

  def id
    @system_id
  end

  def subscribe

  end

  private def get_parts(module_id)
    module_name, match, index = module_id.to_s.rpartition('_')
    if match.empty?
      {module_id, 1}
    else
      {module_name, index.to_i}
    end
  end
end
