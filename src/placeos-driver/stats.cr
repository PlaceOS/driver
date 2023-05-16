require "gc"
require "./protocol"

module PlaceOS::Driver::Stats
  # :nodoc:
  Log = ::Log.for(self)

  # Useful for debugging, it outputs memory usage and internal protocol queue values
  #
  # to obtain the stats you need to signal the process `kill -s USR2 %PID`
  def self.dump_stats
    total = GC.stats.total_bytes
    stats = GC.prof_stats
    one_mib = 1048576
    memory = "Memory Usage:\n - Free: #{(stats.free_bytes / one_mib).round(1)}MiB\n - Heap: #{(stats.heap_size / one_mib).round(1)}MiB\n - Total: #{(total / one_mib).round(1)}MiB\n - Unmapped #{(stats.unmapped_bytes / one_mib).round(1)}MiB\n - Non GC Bytes #{(stats.non_gc_bytes / one_mib).round(1)}MiB"

    protocol = ::PlaceOS::Driver::Protocol.instance
    protocol_stats = "Protocol:\n - Tracking: #{protocol.@tracking.size}\n - Current: #{protocol.@current_requests.size}\n - Next: #{protocol.@next_requests.size}"

    Log.warn { "\n\n#{memory}\n#{protocol_stats}\n\n" }
  end

  # :nodoc:
  def self.setup_signal
    Signal::USR2.trap do |signal|
      spawn { PlaceOS::Driver::Stats.dump_stats }
      signal.ignore
      setup_signal
    end
  end
end

PlaceOS::Driver::Stats.setup_signal
