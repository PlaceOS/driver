require "json"

class Object
  # :nodoc:
  def try_to_json(fallback = nil)
    {% begin %}
      {% if @type.ancestors.includes?(Number) %}
         return self.to_json
      {% end %}
      {% for m in @type.methods %}
        {% if m.name == "to_json" %}
          {% if m.args.size == 1 %}
            {% if m.args[0].restriction.stringify == "JSON::Builder" %}
              return self.to_json
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    {% end %}
    fallback
  end
end
