require "../storage"

class PlaceOS::Driver::EdgeStorage < PlaceOS::Driver::Storage
  def initialize(@id : String, @prefix = DEFAULT_PREFIX)
    super()
    @hash_key = "#{prefix}/#{@id}"
  end

  getter hash_key : String
  getter id : String
  getter prefix : String

  def []=(status_name, json_value)
    status_name = status_name.to_s
    adjusted_value = json_value.to_s.presence

    if adjusted_value
      upsert(status_name, adjusted_value)
      PlaceOS::Driver::Protocol.instance.request(@id, "status", "#{hash_key}/#{status_name}\x03#{adjusted_value}", raw: true)
    else
      delete(status_name)
    end
    json_value
  end

  # This is the same as setting a value as this is often used when
  # a hash value is updated and we want to notify of this change
  def signal_status(status_name) : String?
    status_name = status_name.to_s
    json_value = self[status_name]?
    adjusted_value = json_value || "null"
    PlaceOS::Driver::Protocol.instance.request(@id, "status", "#{hash_key}/#{status_name}\x03#{adjusted_value}", raw: true)
    json_value
  end

  def delete(key)
    key = key.to_s
    value = delete_impl(key)
    if value
      PlaceOS::Driver::Protocol.instance.request(@id, "status", "#{hash_key}/#{key}\x03null", raw: true)
      return value
    end
    yield key
  end

  def clear
    clear_impl
    PlaceOS::Driver::Protocol.instance.request(@id, "clear", hash_key, raw: true)
    self
  end
end
