class EngineDriver::Status < Hash(String, String)
  def set_json(key, value)
    self[key.to_s] = value.to_json
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
