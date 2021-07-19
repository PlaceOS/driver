abstract class PlaceOS::Driver; end

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

  abstract def fetch(key, &block : String ->)

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

  abstract def delete(key, &block : String ->)

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

# Fix for a Hash dup issues on crystal 0.36.0
{% if compare_versions(Crystal::VERSION, "0.36.0") == 0 %}
  class Hash(K, V)
    def dup
      hash = Hash(K, V).new
      hash.initialize_dup(self)
      hash
    end
  end
{% end %}

require "./storage/redis-storage"
