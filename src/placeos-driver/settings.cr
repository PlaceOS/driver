require "json"

class PlaceOS::Driver::Settings
  def initialize(settings : String)
    @json = JSON.parse(settings).as_h
  end

  def initialize(@json : Hash(String, JSON::Any))
  end

  @json : Hash(String, JSON::Any)
  property :json

  def get
    with self yield
  end

  def raw(*keys)
    keys = keys.map &.to_s
    @json.dig(*keys)
  end

  def raw?(*keys)
    keys = keys.map &.to_s
    @json.dig?(*keys)
  end

  def [](key)
    @json[key.to_s]
  end

  def []?(key)
    @json[key.to_s]?
  end

  macro setting(klass, *keys)
    %keys = {{keys}}.map &.to_s
    %json = json.dig?(*%keys)
    if %json
      begin
        extract {{klass}}, %json
      rescue ex : TypeCastError
        logger.error { "setting[#{%keys.join("->")}] expected to be type of {{klass}}" }
        raise ex
      end
    else
      raise "setting not found: #{%keys.join("->")}"
    end
  end

  macro setting?(klass, *keys)
    %keys = {{keys}}.map &.to_s
    %json = json.dig?(*%keys)
    # Explicitly check for nil here as this is a valid return value for ?
    if %json && %json != nil
      begin
        extract {{klass}}, %json
      rescue ex : TypeCastError
        logger.error { "setting[#{%keys.join("->")}] expected to be type of {{klass}}" }
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
    {% for key, value in PlaceOS::Driver::Settings::JSON_TYPES %}
      {% if ks == key %}
        {% found = true %}
        {% if key.starts_with?("Float") %}
          value = {{json}}.raw
          case value
          when Float64, Int64
            # Floats can't be implicitly cast from Int64
            value.to_{{value.id}}
          else
            # Raise a casting error if not valid
            {{json}}.as_{{value.id}}
          end
        {% else %}
          {{json}}.as_{{value.id}}
        {% end %}
      {% end %}
    {% end %}
    {% if !found %}
      # support Enum value names
      %klass = {{klass}}
      if %klass.responds_to?(:parse)
        value = {{json}}.raw
        case value
        when String
          %klass.parse(value)
        when Int64
          if %klass.responds_to?(:from_value)
            %klass.from_value(value)
          else
            %klass.from_json({{json}}.to_json)
          end
        else
          %klass.from_json({{json}}.to_json)
        end
      else
        %klass.from_json({{json}}.to_json)
      end
    {% end %}
  end
end
