abstract class PlaceOS::Driver; end

# Abstraction of a redis hset
abstract class PlaceOS::Driver::Storage
  DEFAULT_PREFIX = "status"

  getter hash_key : String
  getter id : String
  getter prefix : String

  def initialize(@id : String, @prefix = DEFAULT_PREFIX)
    @hash_key = "#{prefix}/#{@id}"
  end

  abstract def signal_status(status_name) : String?
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
