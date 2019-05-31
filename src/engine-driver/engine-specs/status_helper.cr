require "json"
require "spec"
require "../storage"

class EngineSpec; end

class EngineSpec::StatusHelper
  def initialize(module_id : String)
    @storage = EngineDriver::Storage.new(module_id)
  end

  def []=(key, json_value)
    @storage[key] = json_value.to_json
  end

  def [](key)
    value = @storage[key]
    JSON.parse(value)
  end

  def []?(key)
    value = @storage[key]?
    value ? JSON.parse(value) : nil
  end

  def delete(key)
    @storage.delete key
  end
end
