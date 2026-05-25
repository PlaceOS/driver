require "gc"
require "./protocol"

module PlaceOS::Driver::Stats
  # :nodoc:
  Log = ::Log.for(self)

  def self.memory_usage
    stats = GC.stats
    one_mib = 1048576

    # live = retained (reachable) bytes. This is the number that climbs on a
    # true object-retention leak; RSS/heap can sit at a high-water mark without
    # leaking. Fiber count climbs on a fiber leak.
    fiber_count = 0
    Fiber.unsafe_each { fiber_count += 1 }

    {
      fibers:         fiber_count,
      stats_live:     "#{((stats.heap_size - stats.free_bytes) / one_mib).round(1)}MiB",
      stats_free:     "#{(stats.free_bytes / one_mib).round(1)}MiB",
      stats_heap:     "#{(stats.heap_size / one_mib).round(1)}MiB",
      stats_total:    "#{(stats.total_bytes / one_mib).round(1)}MiB",
      stats_unmapped: "#{(stats.unmapped_bytes / one_mib).round(1)}MiB",
    }
  end

  def self.protocol_tracking
    protocol = PlaceOS::Driver::Protocol.instance
    {
      tracking: protocol.@tracking.size,
      current:  protocol.@current_requests.size,
      next:     protocol.@next_requests.size,
    }
  end

  # Useful for debugging, it outputs memory usage and internal protocol queue values
  #
  # to obtain the stats you need to signal the process `kill -s USR2 %PID`
  def self.dump_stats
    Log.warn { "\n\n#{memory_usage}\n#{protocol_tracking}\n\n" }
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
