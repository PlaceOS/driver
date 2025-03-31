abstract class PlaceOS::Driver; end

# :nodoc:
# Abstraction of a redis hset
abstract class PlaceOS::Driver::Storage
  include Enumerable({String, String})
  include Iterable({String, String})

  DEFAULT_PREFIX = "status"

  getter hash_key : String { "#{prefix}/#{id}" }
  getter id : String
  getter prefix : String

  def initialize(@id : String, @prefix = DEFAULT_PREFIX)
  end

  abstract def signal_status(status_name) : String?

  abstract def []=(status_name, json_value)

  abstract def fetch(key, &_block : String ->)

  def fetch(key, default)
    fetch(key) { default }
  end

  def [](key, & : String -> String)
    fetch(key) { yield }
  end

  def [](key)
    fetch(key) { raise KeyError.new "Missing hash key: #{key.inspect}" }
  end

  def []?(key)
    fetch(key, nil)
  end

  abstract def delete(key, &_block : String ->)

  def delete(key)
    delete(key) { nil }
  end

  abstract def to_h : Hash(String, String)

  abstract def keys

  abstract def values

  abstract def size

  abstract def empty?

  abstract def clear

  delegate each, to: to_h
end

require "./storage/redis-storage"
