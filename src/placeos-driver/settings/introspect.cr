require "json"

class PlaceOS::Driver::Settings
  # key => {class, required}
  SETTINGS_REQ = {} of Nil => Nil

  module Introspect
    def __generate_json_schema__
      {% begin %}
        {% properties = {} of Nil => Nil %}
        {% for ivar in @type.instance_vars %}
          {% ann = ivar.annotation(::JSON::Field) %}
          {% unless ann && (ann[:ignore] || ann[:ignore_deserialize]) %}
            {% properties[((ann && ann[:key]) || ivar).id] = ivar.type %}
          {% end %}
        {% end %}

        {% if properties.empty? %}
          { type: "object" }
        {% else %}
          {type: "object",  properties: {
            {% for key, ivar in properties %}
              {{key}}: PlaceOS::Driver::Settings.introspect({{ivar.resolve.name}}),
            {% end %}
          },
            {% required = [] of String %}
            {% for key, ivar in properties %}
              {% unless ivar.nilable? %}
                {% required << key.stringify %}
              {% end %}
            {% end %}
            {% unless required.empty? %}
              required: [
              {% for key in required %}
                {{key}},
              {% end %}
              ]
            {% end %}
          }
        {% end %}
      {% end %}
    end
  end

  module ::JSON::Serializable
    macro included
      extend ::PlaceOS::Driver::Settings::Introspect
    end
  end

  macro introspect(klass)
    {% arg_name = klass.stringify %}
    {% if !arg_name.starts_with?("Union") && arg_name.includes?("|") %}
      PlaceOS::Driver::Settings.introspect(Union({{klass}}))
    {% else %}
      {% klass = klass.resolve %}
      {% klass_name = klass.name(generic_args: false) %}

      {% if klass <= Array %}
        {% if klass.type_vars.size == 1 %}
          has_items = PlaceOS::Driver::Settings.introspect {{klass.type_vars[0]}}
        {% else %}
          has_items = {} of String => String
        {% end %}
        if has_items.empty?
          %klass = {{klass}}
          %klass.responds_to?(:json_schema) ? %klass.json_schema : {type: "array"}
        else
          {type: "array", items: has_items}
        end
      {% elsif klass.union? %}
        { anyOf: [
          {% for type in klass.union_types %}
            PlaceOS::Driver::Settings.introspect({{type}}),
          {% end %}
        ]}
      {% elsif klass_name.starts_with? "Tuple(" %}
        has_items = [
          {% for generic in klass.type_vars %}
            PlaceOS::Driver::Settings.introspect({{generic}}),
          {% end %}
        ]
        {type: "array", items: has_items}
      {% elsif klass_name.starts_with? "NamedTuple(" %}
        {type: "object",  properties: {
          {% for key in klass.keys %}
            {{key.id}}: PlaceOS::Driver::Settings.introspect({{klass[key].resolve.name}}),
          {% end %}
        },
          {% required = [] of String %}
          {% for key in klass.keys %}
            {% if !klass[key].resolve.nilable? %}
              {% required << key.id.stringify %}
            {% end %}
          {% end %}
          {% if !required.empty? %}
            required: [
            {% for key in required %}
              {{key}},
            {% end %}
            ]
          {% end %}
        }
      {% elsif klass < Enum %}
        {type: "string",  enum: {{klass.constants.map(&.stringify)}} }
      {% elsif klass <= String %}
        { type: "string" }
      {% elsif klass <= Bool %}
        { type: "boolean" }
      {% elsif klass <= Int %}
        { type: "integer" }
      {% elsif klass <= Float %}
        { type: "number" }
      {% elsif klass <= Nil %}
        { type: "null" }
      {% elsif klass <= Hash %}
        {% if klass.type_vars.size == 2 %}
          { type: "object", additionalProperties: PlaceOS::Driver::Settings.introspect({{klass.type_vars[1]}}) }
        {% else %}
          # As inheritance might include the type_vars it's hard to work them out
          %klass = {{klass}}
          %klass.responds_to?(:json_schema) ? %klass.json_schema : { type: "object" }
        {% end %}
      {% elsif klass.ancestors.includes? JSON::Serializable %}
        {{klass}}.__generate_json_schema__
      {% else %}
        %klass = {{klass}}
        if %klass.responds_to?(:json_schema)
          %klass.json_schema
        else
          # anything will validate (JSON::Any)
          {} of String => String
        end
      {% end %}
    {% end %}
  end
end
