require "redis-cluster"
require "../storage"

# Abstraction of a redis hset
class PlaceOS::Driver::RedisStorage < PlaceOS::Driver::Storage
  REDIS_URL = ENV["REDIS_URL"]? || "redis://localhost:6379"

  @@mutex : Mutex = Mutex.new(:reentrant)

  def signal_status(status_name) : String?
    status_name = status_name.to_s
    key = "#{hash_key}/#{status_name}"
    json_value = self[status_name]?
    adjusted_value = json_value || "null"
    @@mutex.synchronize { redis.publish(key, adjusted_value) }
    json_value
  end

  # Hash methods
  #################################################################################################

  forward_missing_to to_h

  def to_h
    hash = {} of String => String
    @@mutex.synchronize { redis.hgetall(hash_key) }.each_slice(2) do |slice|
      hash[slice[0].to_s] = slice[1].to_s
    end
    hash
  end

  def []=(status_name, json_value)
    status_name = status_name.to_s
    adjusted_value = json_value.to_s.presence

    if adjusted_value
      @@mutex.synchronize do
        redis.pipelined(hash_key, reconnect: true) do |pipeline|
          pipeline.hset(hash_key, status_name, adjusted_value)
          pipeline.publish("#{hash_key}/#{status_name}", adjusted_value)
        end
      end
    else
      delete(status_name)
    end
    json_value
  end

  def fetch(key)
    key = key.to_s
    entry = @@mutex.synchronize { redis.hget(hash_key, key) }
    entry ? entry.to_s : yield key
  end

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

  def delete(key)
    key = key.to_s
    value = self[key]?
    if value
      @@mutex.synchronize do
        redis.pipelined(hash_key, reconnect: true) do |pipeline|
          pipeline.hdel(hash_key, key)
          pipeline.publish("#{hash_key}/#{key}", "null")
        end
      end
      return value.to_s
    end
    yield key
  end

  def delete(key)
    delete(key) { nil }
  end

  def keys
    @@mutex.synchronize { redis.hkeys(hash_key) }.map &.to_s
  end

  def values
    @@mutex.synchronize { redis.hvals(hash_key) }.map &.to_s
  end

  def size
    @@mutex.synchronize { redis.hlen(hash_key) }
  end

  def empty?
    size == 0
  end

  def clear
    hkey = hash_key
    @@mutex.synchronize do
      keys = redis.hkeys(hkey)
      redis.pipelined(hkey, reconnect: true) do |pipeline|
        keys.each do |key|
          pipeline.hdel(hkey, key)
          pipeline.publish("#{hkey}/#{key}", "null")
        end
      end
    end
    self
  end

  # Redis
  #############################################################################

  private class_getter redis_lock = Mutex.new
  private getter redis : Redis::Client { self.class.shared_redis_client }

  def self.get(key)
    @@mutex.synchronize { shared_redis_client.get(key.to_s) }
  end

  def self.with_redis
    @@mutex.synchronize { yield shared_redis_client }
  end

  protected def self.new_redis_client
    Redis::Client.boot(REDIS_URL)
  end

  @@redis : Redis::Client? = nil

  protected def self.shared_redis_client
    @@mutex.synchronize { @@redis ||= new_redis_client }
  end
end
