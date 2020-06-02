require "json"
require "../storage"
require "spec/dsl"
require "spec/methods"
require "spec/expectations"

class DriverSpecs; end

class DriverSpecs::StatusHelper
  def initialize(module_id : String)
    @storage = PlaceOS::Driver::Storage.new(module_id)
  end

  def []=(key, value)
    key = key.to_s
    if value.nil?
      delete(key)
    else
      @storage[key] = value.to_json
    end
    value
  end

  def [](key)
    value = @storage[key]
    JSON.parse(value)
  end

  def []?(key)
    value = @storage[key]?
    value ? JSON.parse(value) : nil
  end

  forward_missing_to @storage
end
