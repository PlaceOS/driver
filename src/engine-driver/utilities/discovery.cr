abstract class EngineDriver
  module Utilities
    class Discovery
      @@settings = {} of Symbol => String | Int32 | Bool
      @@requirements = {} of String => Array(String)

      def self.settings
        @@settings
      end

      def self.requirements
        @@requirements
      end

      def self.defaults : String
        @@settings[:default_settings] ||= "{}"
        @@settings.to_json
      end
    end
  end

  def self.descriptive_name(name)
    Utilities::Discovery.settings[:descriptive_name] = name.to_s
  end

  def self.generic_name(name)
    Utilities::Discovery.settings[:generic_name] = name.to_s
  end

  def self.description(markdown)
    Utilities::Discovery.settings[:description] = markdown.to_s
  end

  def self.tcp_port(port)
    Utilities::Discovery.settings[:generic_name] = port.to_i
  end

  def self.udp_port(port)
    Utilities::Discovery.settings[:udp_port] = port.to_i
  end

  def self.uri_base(url)
    Utilities::Discovery.settings[:uri_base] = url.to_s
  end

  def self.makebreak!
    Utilities::Discovery.settings[:makebreak] = true
  end

  def self.default_settings(hash)
    Utilities::Discovery.settings[:default_settings] = hash.to_json
  end

  # Creates helper methods for accessing proxy objects
  macro accessor(name, implementing = nil)
    {% ntype = name.type %}
    {% optional = false %}
    {% collection = false %}

    {% if ntype.is_a?(Union) %}
      # Anything with a ? goes here: Array(Int32)? + Int32?
      {% ntype = name.type.types[0] %}
      {% if name.type.types[1].stringify == "::Nil" || name.type.types[1].stringify == "Nil" %}
        {% optional = true %}
      {% else %}
        {{ "Can only specify a single driver class when aliasing".id }}
      {% end %}
    {% end %}

    {% if ntype.is_a?(Path) %}
      # Direct type: Int32, Display
      # puts "{{name.var}} - {{ntype}} - {{optional}}"
      {% ntype = ntype.stringify %}
    {% else %}
      {% if ntype.name.stringify == "Array" %}
        {% collection = true %}
        # puts "{{name.var}} - {{ntype.name}} - {{ntype.type_vars[0]}} - {{optional}}"
        {% ntype = ntype.type_vars[0].stringify %}
      {% else %}
        {{ "Only generic type supported is Array".id }}
      {% end %}
    {% end %}

    # Ensure implementing is an Array
    {% if implementing %}
      {% if !implementing.is_a?(ArrayLiteral) %}
        {% implementing = [implementing.id.stringify] %}
      {% else %}
        {% implementing = implementing.map(&.id.stringify) %}
      {% end %}
    {% else %}
      {% implementing = "[] of String".id %}
    {% end %}

    # non optional requirements to be recorded
    {% if !optional %}
      %requirements = Utilities::Discovery.requirements
      %existing = %requirements[{{ntype}}]? || [] of String
      %existing += {{implementing}}
      %existing.uniq!
      %requirements[{{ntype}}] = %existing
    {% end %}

    protected def {{name.var}}
      {% if collection %}
        system.all({{ntype}})
      {% else %}
        system[{{ntype.stringify}}]
      {% end %}
    end
  end
end
