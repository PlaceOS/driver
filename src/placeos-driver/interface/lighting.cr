require "json"

abstract class PlaceOS::Driver
  module Interface::Lighting
    struct Area
      include JSON::Serializable

      # Newer fields can be added if these don't meet requirements for newer lighting systems
      getter id : UInt32?
      getter join : UInt32?
      getter channel : UInt32?
      getter component : String?

      @[JSON::Field(ignore: true)]
      property append : String? = nil

      def initialize(@id = nil, @channel = nil, @component = nil, @join = nil, @append = nil)
      end

      def join_with(area : Area) : Area
        local_join = join || area.join
        remote_join = area.join || local_join

        if local_join && remote_join
          Area.new(id, channel, component, local_join | remote_join)
        else
          self
        end
      end

      def append(@append : String?)
        self
      end

      def to_s
        ["area#{id}", channel, component, join, append].compact.join("_")
      end
    end

    # Expects status is set as `self[area] = scene`
    module Scene
      abstract def set_lighting_scene(scene : UInt32, area : Area? = nil, fade_time : UInt32 = 1000_u32)
      abstract def lighting_scene?(area : Area? = nil)
    end

    # Expects status is set as `self[area.append("level")] = level`
    module Level
      # level between 0.0 and 100.0, fade in milliseconds
      abstract def set_lighting_level(level : Float64, area : Area? = nil, fade_time : UInt32 = 1000_u32)

      # return the current level
      abstract def lighting_level?(area : Area? = nil)

      def set_lighting(state : Bool, area : Area? = nil, fade_time : UInt32 = 1000_u32)
        level = state ? 100.0 : 0.0
        set_lighting_level level, area, fade_time
      end
    end
  end
end
