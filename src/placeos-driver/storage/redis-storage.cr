require "redis-cluster"
require "../storage"

# Abstraction of a redis hset
class PlaceOS::Driver::RedisStorage < PlaceOS::Driver::Storage
  REDIS_URL = ENV["REDIS_URL"]? || "redis://localhost:6379"

  @@redis_lock : Mutex = Mutex.new(:reentrant)

  def signal_status(status_name) : String?
    status_name = status_name.to_s
    key = "#{hash_key}/#{status_name}"
    json_value = self[status_name]?
    adjusted_value = json_value || "null"
    @@redis_lock.synchronize { redis.publish(key, adjusted_value) }
    json_value
  end

  # Hash methods
  #################################################################################################

  forward_missing_to to_h

  def each
    @@redis_lock.synchronize { redis.hgetall(hash_key) }
      .each_slice(2, reuse: true)
      .map { |(key, value)| {key.to_s, value.to_s} }
  end

  def to_h
    each.each.each_with_object({} of String => String) do |(key, value), hash|
      hash[key] = value
    end
  end

  def []=(status_name, json_value)
    status_name = status_name.to_s
    adjusted_value = json_value.to_s.presence

    if adjusted_value
      @@redis_lock.synchronize do
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

  def fetch(key, &block : String ->)
    key = key.to_s
    entry = @@redis_lock.synchronize { redis.hget(hash_key, key) }
    entry ? entry.to_s : yield key
  end

  def delete(key, &block : String ->)
    key = key.to_s
    value = self[key]?
    if value
      @@redis_lock.synchronize do
        redis.pipelined(hash_key, reconnect: true) do |pipeline|
          pipeline.hdel(hash_key, key)
          pipeline.publish("#{hash_key}/#{key}", "null")
        end
      end
      return value.to_s
    end
    yield key
  end

  def keys
    @@redis_lock.synchronize { redis.hkeys(hash_key) }.map &.to_s
  end

  def values
    @@redis_lock.synchronize { redis.hvals(hash_key) }.map &.to_s
  end

  def size
    @@redis_lock.synchronize { redis.hlen(hash_key) }
  end

  def empty?
    size == 0
  end

  def clear
    hkey = hash_key
    @@redis_lock.synchronize do
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

  private getter redis : Redis::Client { self.class.shared_redis_client }

  def self.get(key)
    @@redis_lock.synchronize { shared_redis_client.get(key.to_s) }
  end

  def self.with_redis
    @@redis_lock.synchronize { yield shared_redis_client }
  end

  protected def self.new_redis_client
    Redis::Client.boot(REDIS_URL)
  end

  @@redis : Redis::Client? = nil

  protected def self.shared_redis_client
    @@redis_lock.synchronize { @@redis ||= new_redis_client }
  end
end
