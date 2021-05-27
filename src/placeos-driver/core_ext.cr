require "json"

class Object
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

# Temporary fix for array shift / pop issue on crystal 1.0.0
# https://github.com/crystal-lang/crystal/pull/10750
# https://github.com/crystal-lang/crystal/issues/10748
class Array(T)
  def unshift(object : T)
    check_needs_resize_for_unshift
    shift_buffer_by(-1)
    @buffer.value = object
    @size += 1

    self
  end

  private def check_needs_resize_for_unshift
    return unless @offset_to_buffer == 0

    # If we have no more room left before the beginning of the array
    # we make the array larger, but point the buffer to start at the middle
    # of the entire allocated memory. In this way, if more elements are unshift
    # later we won't need a reallocation right away. This is similar to what
    # happens when we push and we don't have more room, except that toward
    # the beginning.

    half_capacity = @capacity // 2
    if @capacity != 0 && half_capacity != 0 && @size <= half_capacity
      # Apply the same heuristic as the case for pushing elements to the array,
      # but in backwards: (note that `@size` can be 0 here)

      # `['c', 'd', -, -, -, -] (@size = 2)`
      (root_buffer + half_capacity).copy_from(@buffer, @size)

      # `['c', 'd', -, 'c', 'd', -]`
      root_buffer.clear(@size)

      # `[-, -, -, 'c', 'd', -]`
      shift_buffer_by(half_capacity)
    else
      double_capacity_for_unshift
    end
  end
end
