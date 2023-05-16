abstract class PlaceOS::Driver
  # :nodoc:
  BINDINGS = {} of Nil => Nil

  # :nodoc:
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

  # a helper for any driver to bind to changes in its own status values
  # *logic drivers* can additionally bind to status values on remote drivers
  #
  # local bind: `bind :power, :power_changed`
  #
  # remote bind: `bind Display_1, :power, :power_changed`
  #
  # the `new_value` provided in the handler is a JSON string
  #
  # you would define your handler as `protected def power_changed(_subscription, new_value : String)`
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
