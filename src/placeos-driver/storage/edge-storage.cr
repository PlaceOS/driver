require "../storage"
require "../protocol"

class PlaceOS::Driver::EdgeStorage < PlaceOS::Driver::Storage
  private getter hash : Hash(String, String) = {} of String => String
  delegate fetch, keys, values, size, to: hash

  def to_h : Hash(String, String)
    hash.dup
  end

  # This is the same as setting a value as this is often used when
  # a hash value is updated and we want to notify of this change.
  def signal_status(status_name) : String?
    status_name = status_name.to_s
    json_value = self[status_name]?
    adjusted_value = json_value || "null"
    PlaceOS::Driver::Protocol.instance.request(hash_key, :hset, "#{status_name}\x03#{adjusted_value}", raw: true)
    json_value
  end

  # Hash methods
  #################################################################################################

  def []=(status_name, json_value)
    status_name = status_name.to_s
    adjusted_value = json_value.to_s.presence

    if adjusted_value
      hash[status_name] = adjusted_value
      PlaceOS::Driver::Protocol.instance.request(hash_key, :hset, "#{status_name}\x03#{adjusted_value}", raw: true)
    else
      delete(status_name)
    end
    json_value
  end

  def delete(key, &block : String ->)
    key = key.to_s
    value = hash.delete(key)
    if value
      PlaceOS::Driver::Protocol.instance.request(hash_key, :hset, "#{key}\x03null", raw: true)
      return value
    end
    yield key
  end

  def clear
    hash.clear
    PlaceOS::Driver::Protocol.instance.request(hash_key, :clear, raw: true)
    self
  end
end
