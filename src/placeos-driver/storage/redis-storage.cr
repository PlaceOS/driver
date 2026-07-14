require "redis-cluster"
require "../storage"

module PlaceOS
  # :nodoc:
  # Abstraction of a redis hset
  class Driver::RedisStorage < Driver::Storage
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

    def to_h : Hash(String, String)
      @@redis_lock.synchronize { redis.hgetall(hash_key) }
    end

    def []=(status_name, json_value)
      status_name = status_name.to_s
      adjusted_value = json_value.to_s.presence || "null"

      if adjusted_value != "null"
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

    # Set a status value that automatically expires after `ttl`.
    #
    # Like `#[]=` but the field is removed by redis once `ttl` elapses. `ttl` may
    # be a `Time::Span` or an integer number of seconds. Setting a `"null"` value
    # deletes the field. Pass `publish: true` to notify subscribers of the change.
    def set_expire(status_name, json_value, ttl : Time::Span | Int, publish : Bool = false)
      status_name = status_name.to_s
      adjusted_value = json_value.to_s.presence || "null"

      if adjusted_value != "null"
        millis = self.class.ttl_milliseconds(ttl)
        @@redis_lock.synchronize do
          if publish
            redis.pipelined(hash_key, reconnect: true) do |pipeline|
              pipeline.hsetex(hash_key, status_name, adjusted_value, px: millis)
              pipeline.publish("#{hash_key}/#{status_name}", adjusted_value)
            end
          else
            redis.hsetex(hash_key, status_name, adjusted_value, px: millis)
          end
        end
      elsif publish
        delete(status_name)
      else
        @@redis_lock.synchronize { redis.hdel(hash_key, status_name) }
      end

      json_value
    end

    # Reset (or set) the expiry on an existing field without changing its value.
    #
    # `ttl` may be a `Time::Span` or an integer number of seconds. No status
    # signal is published as the value is unchanged. Returns `true` when the
    # expiry was applied, `false` when the field does not exist.
    def expire(status_name, ttl : Time::Span | Int) : Bool
      status_name = status_name.to_s
      millis = self.class.ttl_milliseconds(ttl)
      result = @@redis_lock.synchronize { redis.hpexpire(hash_key, millis, status_name) }
      result.first? == 1_i64
    end

    def fetch(key, & : String ->)
      key = key.to_s
      entry = @@redis_lock.synchronize { redis.hget(hash_key, key) }
      entry ? entry.to_s : yield key
    end

    def delete(key, & : String ->)
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

    # Normalise a `Time::Span` or integer number of seconds into milliseconds.
    def self.ttl_milliseconds(ttl : Int) : Int64
      ttl.to_i64 * 1000
    end

    def self.ttl_milliseconds(ttl : Time::Span) : Int64
      ttl.total_milliseconds.round.to_i64
    end

    def self.get(key)
      @@redis_lock.synchronize { shared_redis_client.get(key.to_s) }
    end

    def self.with_redis(&)
      @@redis_lock.synchronize { yield shared_redis_client }
    end

    protected def self.new_redis_client
      Redis::Client.boot(REDIS_URL)
    end

    @@redis : Redis::Client? = nil

    def self.shared_redis_client : Redis::Client
      @@redis || @@redis_lock.synchronize { @@redis ||= new_redis_client }
    end

    def self.redis_lock : Mutex
      @@redis_lock
    end
  end
end
