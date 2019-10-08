require "json"
require "../storage"
require "spec/dsl"
require "spec/methods"
require "spec/expectations"

class EngineSpec; end

class EngineSpec::StatusHelper
  def initialize(module_id : String)
    @storage = ACAEngine::Driver::Storage.new(module_id)
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
