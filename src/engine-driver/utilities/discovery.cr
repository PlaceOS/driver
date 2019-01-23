abstract class EngineDriver
  module Utilities
    class Discovery
      @@settings = {} of Symbol => String | Int32 | Bool

      def self.settings
        @@settings
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
end
