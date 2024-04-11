abstract class PlaceOS::Driver
  # :nodoc:
  RESCUE_FROM = {} of Nil => Nil

  # provides a generic method for handling otherwise unhandled errors in your drivers functions
  # i.e. `rescue_from(DivisionByZeroError, :return_zero)`
  # or alternatively: `rescue_from(DivisionByZeroError) { 0 }`
  macro rescue_from(error_class, method = nil, &block)
    {% if method %}
      {% RESCUE_FROM[error_class] = {method.id, nil} %}
    {% else %}
      {% method = "__on_" + error_class.stringify.underscore.gsub(/\:\:/, "_") %}
      {% RESCUE_FROM[error_class] = {method.id, block} %}
    {% end %}
  end

  # :nodoc:
  macro _rescue_from_inject_functions_
    # Create functions as required for errors
    # Skip the generating methods for existing handlers
    {% for klass, details in RESCUE_FROM %}
      {% block = details[1] %}
      {% if block != nil %}
        protected def {{details[0]}}({{details[1].args.splat}})
          {{details[1].body}}
        end
      {% end %}
    {% end %}
  end
end
