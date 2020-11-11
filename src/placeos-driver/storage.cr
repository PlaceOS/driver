abstract class PlaceOS::Driver; end

# Abstraction of a redis hset
abstract class PlaceOS::Driver::Storage < Hash(String, String)
  DEFAULT_PREFIX = "status"

  abstract def signal_status(status_name) : String?
end

require "./storage/redis-storage"
