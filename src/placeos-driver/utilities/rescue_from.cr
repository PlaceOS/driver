abstract class PlaceOS::Driver
  RESCUE_FROM = {} of Nil => Nil

  macro rescue_from(error_class, method = nil, &block)
    {% if method %}
      {% RESCUE_FROM[error_class] = {method.id, nil} %}
    {% else %}
      {% method = "__on_" + error_class.stringify.underscore.gsub(/\:\:/, "_") %}
      {% RESCUE_FROM[error_class] = {method.id, block} %}
    {% end %}
  end

  macro _rescue_from_inject_functions_
    # Create functions as required for errors
    # Skip the generating methods for existing handlers
    {% for klass, details in RESCUE_FROM %}
      {% block = details[1] %}
      {% if block != nil %}
        protected def {{details[0]}}({{*details[1].args}})
          {{details[1].body}}
        end
      {% end %}
    {% end %}
  end
end
