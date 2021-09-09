class PlaceOS::Driver::Status
  private getter hash = {} of String => String
  forward_missing_to hash

  def set_json(key, value)
    key = key.to_s
    current_value = self[key]? || "null"
    new_value = value.is_a?(::Enum) ? value.to_s.to_json : value.to_json
    if current_value == new_value
      {current_value, false}
    elsif current_value == "null"
      self.delete key
      {new_value, true}
    else
      self[key] = new_value
      {new_value, true}
    end
  end

  def fetch_json(key) : JSON::Any
    JSON.parse(self[key.to_s])
  end

  # Fetch JSON with default value provided in block
  def fetch_json(key) : JSON::Any
    value = self[key.to_s]?
    if value
      JSON.parse(value)
    else
      value = yield
      value.is_a?(JSON::Any) ? value : JSON.parse(value.to_json)
    end
  end

  def fetch_json?(key) : JSON::Any?
    value = self[key.to_s]?
    JSON.parse(value) if value
  end
end
