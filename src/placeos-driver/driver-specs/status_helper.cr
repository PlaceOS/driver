require "json"
require "../storage"
require "spec/dsl"
require "spec/methods"
require "spec/expectations"

class DriverSpecs; end

class DriverSpecs::StatusHelper
  def initialize(module_id : String)
    @storage = PlaceOS::Driver::RedisStorage.new(module_id)
  end

  # Expose a status key to other mock drivers and the driver we're testing
  def []=(key, value)
    key = key.to_s
    if value.nil?
      delete(key)
    else
      @storage[key] = value.to_json
    end
    value
  end

  # returns the current value of a status value and raises if it does not exist
  def [](key)
    value = @storage[key]
    JSON.parse(value)
  end

  # returns the current value of a status value and nil if it does not exist
  def []?(key)
    value = @storage[key]?
    value ? JSON.parse(value) : nil
  end

  forward_missing_to @storage
end
