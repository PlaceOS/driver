require "json"

class EngineDriver::Settings
  def initialize(settings : String)
    @json = JSON.parse(settings)
  end

  getter :json

  def get
    with self yield
  end

  macro setting(klass, *keys)
    %keys = {{keys}}.map &.to_s
    %json = json.dig?(*%keys)
    if %json
      begin
        extract {{klass}}, %json
      rescue ex : TypeCastError
        # TODO:: improve logging
        puts "setting[#{%keys.join("->")}] expected to be type of {{klass}}"
        raise ex
      end
    else
      raise "setting not found: #{%keys.join("->")}"
    end
  end

  macro setting?(klass, *keys)
    %keys = {{keys}}.map &.to_s
    %json = json.dig?(*%keys)
    if %json
      begin
        extract {{klass}}, %json
      rescue ex : TypeCastError
        # TODO:: improve logging
        puts "setting[#{%keys.join("->")}] expected to be type of {{klass}}"
        raise ex
      end
    else
      nil
    end
  end

  JSON_TYPES = {
    "Bool":    "bool",
    "Float64": "f",
    "Float32": "f32",
    "Int32":   "i",
    "Int64":   "i64",
    "Nil":     "nil",
    "String":  "s",
  }

  macro extract(klass, json)
    {% ks = klass.id.stringify %}
    {% found = false %}
    {% for key, value in EngineDriver::Settings::JSON_TYPES %}
      {% if ks == key %}
        {% found = true %}
        {{json}}.as_{{value.id}}
      {% end %}
    {% end %}
    {% if !found %}
      {{klass}}.from_json({{json}}.to_json)
    {% end %}
  end
end
