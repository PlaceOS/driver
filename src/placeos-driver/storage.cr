require "redis"

abstract class PlaceOS::Driver; end

# Abstraction of a redis hset
class PlaceOS::Driver::Storage < Hash(String, String)
  @@redis_pool : Redis::PooledClient?

  REDIS_URL  = ENV["REDIS_URL"]?
  REDIS_HOST = ENV["REDIS_HOST"]? || "localhost"
  REDIS_PORT = (ENV["REDIS_PORT"]? || 6379).to_i

  def self.redis_pool : Redis::PooledClient
    if REDIS_URL
      @@redis_pool ||= Redis::PooledClient.new(url: REDIS_URL)
    else
      @@redis_pool ||= Redis::PooledClient.new(host: REDIS_HOST, port: REDIS_PORT)
    end
  end

  def self.get(key)
    redis_pool.get(key.to_s)
  end

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

  def initialize(@id : String, prefix = DEFAULT_PREFIX)
    super()
    @redis = self.class.redis_pool
    @hash_key = "#{prefix}/#{@id}"
  end

  @redis : Redis::PooledClient
  getter hash_key, redis, prefix, id

  def []=(status_name, json_value)
    if json_value.nil?
      delete(status_name)
    else
      status_name = status_name.to_s
      key = hash_key
      @redis.pipelined do |pipeline|
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
      @redis.publish("#{hash_key}/#{status_name}", json_value)
    else
      @redis.publish("#{hash_key}/#{status_name}", "null")
    end
    json_value
  end

  def fetch(key)
    key = key.to_s
    entry = @redis.hget(hash_key, key)
    entry ? entry.to_s : yield key
  end

  def delete(key)
    key = key.to_s
    value = self[key]?
    if value
      hkey = hash_key
      @redis.pipelined do |pipeline|
        pipeline.hdel(hkey, key)
        pipeline.publish("#{hkey}/#{key}", "null")
      end
      return value.to_s
    end
    yield key
  end

  def keys
    @redis.hkeys(hash_key).map &.to_s
  end

  def values
    @redis.hvals(hash_key).map &.to_s
  end

  def size
    @redis.hlen(hash_key)
  end

  def empty?
    size == 0
  end

  def to_h
    hash = {} of String => String
    @redis.hgetall(hash_key).each_slice(2) do |slice|
      hash[slice[0].to_s] = slice[1].to_s
    end
    hash
  end

  def clear
    hkey = hash_key
    keys = @redis.hkeys(hkey)
    @redis.pipelined do |pipeline|
      keys.each do |key|
        pipeline.hdel(hkey, key)
        pipeline.publish("#{hkey}/#{key}", "null")
      end
    end
    self
  end
end
