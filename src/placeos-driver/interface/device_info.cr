require "json"

abstract class PlaceOS::Driver
  module Interface::DeviceInfo
    struct Descriptor
      include JSON::Serializable

      def initialize(
        @make,
        @model,
        @serial = nil,
        @firmware = nil,
        @mac_address = nil,
        @ip_address = nil,
        @hostname = nil,
      )
      end

      # The manufacturer of the device
      property make : String

      # The product identifier
      property model : String

      # The unique identifier
      property serial : String?

      # The version of code running on the device
      property firmware : String?

      # The network hardware address
      property mac_address : String?

      # The network address
      property ip_address : String?

      # The DNS/mDNS name of the device
      property hostname : String?
    end

    macro included
      alias Descriptor = ::PlaceOS::Driver::Interface::DeviceInfo::Descriptor

      @__device_info_schedule__ : PlaceOS::Driver::Proxy::Scheduler::TaskWrapper? = nil
      @__device_info_now__ : PlaceOS::Driver::Proxy::Scheduler::TaskWrapper? = nil

      macro finished
        def connected
          previous_def
        ensure
          @__device_info_schedule__ = schedule.every(1.hour) { update_device_info }
          @__device_info_now__ = schedule.in(5.seconds + rand(5000).milliseconds) { update_device_info }
        end

        def disconnected
          previous_def
        ensure
          @__device_info_schedule__.try(&.cancel) rescue nil
          @__device_info_schedule__ = nil

          @__device_info_now__.try(&.cancel) rescue nil
          @__device_info_now__ = nil
        end
      end
    end

    # the target class must implement this function
    abstract def device_info : Descriptor

    def update_device_info
      signal_status("connected") rescue nil
      self[:device_info] = device_info
    end
  end
end
