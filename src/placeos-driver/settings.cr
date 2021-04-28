require "./settings/introspect"

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

  def self.get
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

  macro add_setting_key(key, klass, required)
    {% arg_name = klass.stringify %}
    {% if !arg_name.starts_with?("Union") && arg_name.includes?("|") %}
      PlaceOS::Driver::Settings.add_setting_key(key, Union({{klass}}), {{required}})
    {% else %}
      {% klass = klass.resolve %}
      {% ::PlaceOS::SETTINGS_REQ[key] = {klass, required} %}
    {% end %}
  end

  macro setting(klass, *keys)
    # We check for key size == 1 as hard to build schema for sub keys
    # this won't prevent the setting from working, just not part of the schema
    {% if keys.size == 1 %}
      add_setting_key {{keys[0].id}}, {{klass}}, true
    {% end %}
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
    {% if keys.size == 1 %}
      add_setting_key {{keys[0].id}}, {{klass}}, false
    {% end %}
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

  macro generate_json_schema
    {
      type: "object",
      {% if !::PlaceOS::SETTINGS_REQ.empty? %}
        properties: {
          {% for key, details in ::PlaceOS::SETTINGS_REQ %}
            {% klass = details[0] %}
            {{key.id}}: PlaceOS.introspect({{klass}}),
          {% end %}
        },
        required: [
          {% for key, details in ::PlaceOS::SETTINGS_REQ %}
            {% required = details[1] %}
            {% if required %}
              {{key.id.stringify}},
            {% end %}
          {% end %}
        ] of String
      {% end %}
    }.to_json
  end
end
