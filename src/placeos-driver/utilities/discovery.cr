abstract class PlaceOS::Driver
  # :nodoc:
  # the transports a driver requires, populated by the discovery macros below
  # and inspected at the end of compilation to require only those transports
  TRANSPORTS = {} of Nil => Nil

  # all transports are compiled when the `placeos_all_transports` flag is
  # defined or the PLACEOS_ALL_TRANSPORTS env var is set at build time.
  # The test-harness sets the env var on its build service as driver specs
  # launch every driver against a mock raw TCP server (role: 1)
  {% if flag?(:placeos_all_transports) || !(env("PLACEOS_ALL_TRANSPORTS") || "").empty? %}
    {% for transport in [:tcp, :udp, :ssh, :http, :websocket] %}
      {% TRANSPORTS[transport] = true %}
    {% end %}
  {% end %}

  module Utilities
    # :nodoc:
    class Discovery
      class_getter settings = {} of Symbol => String | Int32 | Bool
      class_getter requirements = {} of String => Array(String)

      class_getter defaults : String do
        json_schema = PlaceOS::Driver::Settings.get { generate_json_schema }
        settings[:default_settings] ||= "{}"
        %(#{settings.to_json.rchop},"json_schema":#{json_schema}})
      end
    end
  end

  # This is the name of the device you are writing a driver for.
  #
  # examples such as: Sony VISCA Camera, Samsung MDC Protocol
  def self.descriptive_name(name)
    Utilities::Discovery.settings[:descriptive_name] = name.to_s
  end

  # This is the name other drivers and frontends will use to access the driver functionality
  #
  # exmaples such as: Camera, Display
  def self.generic_name(name)
    Utilities::Discovery.settings[:generic_name] = name.to_s
  end

  # provide a description for your driver that will be diplayed in backoffice.
  #
  # it supports rendering markdown, so you can provide links to manuals and photos etc
  def self.description(markdown)
    Utilities::Discovery.settings[:description] = markdown.to_s
  end

  # define a TCP port default if your driver connects over a raw TCP socket
  #
  # this compiles the TCP and SSH transports into the driver
  macro tcp_port(port)
    {% ::PlaceOS::Driver::TRANSPORTS[:tcp] = true %}
    {% ::PlaceOS::Driver::TRANSPORTS[:ssh] = true %}
    ::PlaceOS::Driver::Utilities::Discovery.settings[:tcp_port] = ({{port}}).to_i
  end

  # define a UDP port default if your driver connects over a raw UDP socket
  #
  # also use this if you are using multicast for communications
  #
  # this compiles the UDP transport into the driver
  macro udp_port(port)
    {% ::PlaceOS::Driver::TRANSPORTS[:udp] = true %}
    ::PlaceOS::Driver::Utilities::Discovery.settings[:udp_port] = ({{port}}).to_i
  end

  # the default base URI for a service driver, all HTTP requests will have this domain and path appended
  #
  # for example: https://api.google.com/
  #
  # this compiles the HTTP and websocket transports into the driver
  macro uri_base(url)
    {% ::PlaceOS::Driver::TRANSPORTS[:http] = true %}
    {% ::PlaceOS::Driver::TRANSPORTS[:websocket] = true %}
    ::PlaceOS::Driver::Utilities::Discovery.settings[:uri_base] = ({{url}}).to_s
  end

  # compile every transport into the binary, regardless of the discovery
  # settings defined. Used by specs and documentation builds, the same can be
  # achieved with the `-Dplaceos_all_transports` compiler flag
  macro load_all_transports
    {% for transport in [:tcp, :udp, :ssh, :http, :websocket] %}
      {% ::PlaceOS::Driver::TRANSPORTS[transport] = true %}
    {% end %}
  end

  # when using a TCP protocol, we want to close the connection after every request / response
  def self.makebreak!
    Utilities::Discovery.settings[:makebreak] = true
  end

  # provide example settings for your driver that can be customised in backoffice
  def self.default_settings(hash)
    Utilities::Discovery.settings[:default_settings] = hash.to_json
  end

  # Creates helper methods in *logic drivers* for accessing other drivers in a system
  #
  # For example, if you want to access `system[:Display_1]` via `display` use `accessor display : Display_1`
  #
  # for `system.all(Camera)` use `accessor cameras : Array(Camera)`
  #
  # for `system.all(Display, implementing: Interface::Powerable)` use `accessor displays : Array(Display), implementing: Interface::Powerable`
  #
  # for `system.implementing(Interface::Powerable)` use `accessor powerable, implementing: Interface::Powerable`
  macro accessor(name, implementing = nil)
    # ntype is the type of the name attribute. i.e. Display
    {% ntype = name.type %}
    {% optional = false %}
    {% collection = false %}
    {% methods = [] of Crystal::Macros::TypeNode %}

    {% if ntype.is_a?(Union) %}
      # Anything with a ? goes here: Array(Int32)? + Int32?
      {% ntype = name.type.types[0] %}
      {% if name.type.types[1].stringify == "::Nil" || name.type.types[1].stringify == "Nil" %}
        {% optional = true %}
      {% else %}
        {{ raise "Can only specify a single driver class when aliasing" }}
      {% end %}
    {% end %}

    {% if ntype.is_a?(Path) %}
      # Direct type: Int32, Display
      # puts "{{name.var}} - {{ntype}} - {{optional}}"
      {% ntype = ntype.stringify %}
      {% if implementing %}
        {% components = ntype.split("_") %}
        {% if components[-1] =~ /\A\d+\z/ %}
          {% components = components[0..-2] %}
        {% end %}
        {% ntype_fixed = components.join("_").id %}
        {{ raise "unsupported use of 'implementing', you probably meant: accessor Array(#{ntype_fixed}), implementing: #{implementing}\nsee options: https://placeos.github.io/driver/PlaceOS/Driver.html#accessor(name,implementing=nil)-macro" }}
      {% end %}
    {% else %}
      {% if ntype.name.stringify == "Array" %}
        {% collection = true %}
        # puts "{{name.var}} - {{ntype.name}} - {{ntype.type_vars[0]}} - {{optional}}"
        {% ntype = ntype.type_vars[0].stringify %}
      {% else %}
        {{ raise "Only generic type supported is Array" }}
      {% end %}
    {% end %}

    # Ensure implementing is an Array
    {% if implementing %}
      {% if !implementing.is_a?(ArrayLiteral) %}
        {% implementing = [implementing] %}
      {% end %}

      # Attempt to inspect the modules so we can have compile time checking
      {% compiler_enforced = true %}
      {% for type in implementing %}
        {% klass = type.resolve? %}
        {% if klass %}
          {% methods = methods + klass.methods %}
          {% klasses = klass.ancestors.reject { |a| IGNORE_KLASSES.includes?(a.stringify) } %}
          {% klasses.map { |a| methods = methods + a.methods } %}
        {% else %}
          {% compiler_enforced = false %}
        {% end %}
      {% end %}

      {% if compiler_enforced %}
        {% methods = methods.reject { |method| RESERVED_METHODS[method.name.stringify] } %}
        {% methods = methods.reject(&.visibility.!=(:public)) %}
        {% methods = methods.reject &.accepts_block? %}
      {% else %}
        {% methods = [] of Crystal::Macros::TypeNode %}
      {% end %}

      # {{methods.map &.name.stringify}} <- How does this look?

      {% implements = implementing.map(&.id.stringify) %}
    {% else %}
      {% implements = [] of String %}
    {% end %}

    # non optional requirements to be recorded
    {% if !optional %}
      %requirements = Utilities::Discovery.requirements
      %existing = %requirements[{{ntype}}]? || [] of String
      %existing += {{implements}}{% if implements.empty? %} of String{% end %}
      %existing.uniq!
      %requirements[{{ntype}}] = %existing
    {% end %}

    protected def {{name.var}}
      {% if collection %}
        {% if implements.empty? %}
          system.all({{ntype}})
        {% else %}
          system.all({{ntype}}, implementing: {{implements[0]}})
        {% end %}
      {% else %}
        {% if implements.empty? %}
          system[{{ntype}}]
        {% else %}
          system.implementing({{implements[0]}})
        {% end %}
      {% end %}
    end
  end
end
