abstract class PlaceOS::Driver
  BINDINGS = {} of Nil => Nil

  macro __build_apply_bindings__
    # :nodoc:
    def __apply_bindings__
      return if @__edge_driver__
      {% for name, details in BINDINGS %}
        {% if details.size == 3 %}
          system.subscribe({{details[0]}}, {{details[1]}}) do |subscription, value|
            {{details[2].id}}(subscription, value)
          end
        {% else %}
          subscribe({{details[0]}}) do |subscription, value|
            {{details[1].id}}(subscription, value)
          end
        {% end %}
      {% end %}
    end
  end

  macro bind(mod, status, handler = nil)
    {% mod = mod.id.stringify %}
    {% status = status.id.stringify %}
    {% if handler %}
      {% handler = handler.id.stringify %}
      {% BINDINGS[mod + status + handler] = [mod, status, handler] %}
    {% else %}
      {% BINDINGS[mod + status] = [mod, status] %}
    {% end %}
  end
end
