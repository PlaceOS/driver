require "redis-cluster"

abstract class PlaceOS::Driver; end

# Abstraction of a redis hset
class PlaceOS::Driver::Storage < Hash(String, String)
  REDIS_URL = ENV["REDIS_URL"]? || "redis://localhost:6379"

  # TODO use enum to restrain prefixes
  # enum Prefix
  #   Status # => "status"
  #   System # => "system"
  #
  #   def to_s
  #     super.downcase
  #   end
  # end

  DEFAULT_PREFIX = "status"

  def initialize(@id : String, @prefix = DEFAULT_PREFIX)
    super()
    @hash_key = "#{prefix}/#{@id}"
  end

  getter hash_key : String
  getter id : String
  getter prefix : String

  def []=(status_name, json_value)
    if json_value.nil?
      delete(status_name)
    else
      status_name = status_name.to_s
      key = hash_key
      redis.pipelined(key, reconnect: true) do |pipeline|
        pipeline.hset(key, status_name, json_value)
        pipeline.publish("#{key}/#{status_name}", json_value)
      end
    end
    json_value
  end

  def signal_status(status_name)
    status_name = status_name.to_s
    json_value = self[status_name]?
    if json_value
      redis.publish("#{hash_key}/#{status_name}", json_value)
    else
      redis.publish("#{hash_key}/#{status_name}", "null")
    end
    json_value
  end

  def fetch(key)
    key = key.to_s
    entry = redis.hget(hash_key, key)
    entry ? entry.to_s : yield key
  end

  def delete(key)
    key = key.to_s
    value = self[key]?
    if value
      hkey = hash_key
      redis.pipelined(hkey, reconnect: true) do |pipeline|
        pipeline.hdel(hkey, key)
        pipeline.publish("#{hkey}/#{key}", "null")
      end
      return value.to_s
    end
    yield key
  end

  def keys
    redis.hkeys(hash_key).map &.to_s
  end

  def values
    redis.hvals(hash_key).map &.to_s
  end

  def size
    redis.hlen(hash_key)
  end

  def empty?
    size == 0
  end

  def to_h
    hash = {} of String => String
    redis.hgetall(hash_key).each_slice(2) do |slice|
      hash[slice[0].to_s] = slice[1].to_s
    end
    hash
  end

  def clear
    hkey = hash_key
    keys = redis.hkeys(hkey)
    redis.pipelined(hkey, reconnect: true) do |pipeline|
      keys.each do |key|
        pipeline.hdel(hkey, key)
        pipeline.publish("#{hkey}/#{key}", "null")
      end
    end
    self
  end

  # Redis
  #############################################################################

  @redis : Redis::Client? = nil

  def redis
    @redis ||= PlaceOS::Driver::Storage.new_redis_client
  end

  def self.get(key)
    client = new_redis_client
    client.get(key.to_s)
  ensure
    client.close
  end

  def self.with_redis
    client = new_redis_client
    yield client
  ensure
    client.try &.close
  end

  protected def self.new_redis_client
    Redis::Client.boot(REDIS_URL)
  end
end
