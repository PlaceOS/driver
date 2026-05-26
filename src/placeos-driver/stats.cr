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

  # Histogram of live fibers grouped by name. Spawns without an explicit name
  # are grouped under "unnamed". A leaking spawn site shows up here as a count
  # that climbs between dumps - which pinpoints the source without guessing.
  def self.fiber_breakdown
    counts = Hash(String, Int32).new(0)
    Fiber.unsafe_each { |fiber| counts[fiber.name || "unnamed"] += 1 }
    counts.to_a.sort_by! { |(_name, count)| -count }
  end

  # Useful for debugging, it outputs memory usage and internal protocol queue values
  #
  # to obtain the stats you need to signal the process `kill -s USR2 %PID`
  def self.dump_stats
    Log.warn { "\n\n#{memory_usage}\n#{protocol_tracking}\nfibers_by_name: #{fiber_breakdown}\n\n" }
  end

  # :nodoc:
  def self.setup_signal
    Signal::USR2.trap do |signal|
      spawn(name: "stats-dump") { PlaceOS::Driver::Stats.dump_stats }
      signal.ignore
      setup_signal
    end
  end
end

PlaceOS::Driver::Stats.setup_signal
