require "gc"

module PlaceOS::Driver::Stats
  Log = ::Log.for(self)

  def self.dump_stats
    stats = GC.stats
    one_mib = 1048576
    Log.warn { "\n\nMemory Usage:\n - Free: #{(stats.free_bytes / one_mib).round(1)}MiB\n - Heap: #{(stats.heap_size / one_mib).round(1)}MiB\n - Total: #{(stats.total_bytes / one_mib).round(1)}MiB\n - Unmapped #{(stats.unmapped_bytes / one_mib).round(1)}MiB\n\n" }
  end
end

Signal::USR1.trap do |signal|
  spawn { PlaceOS::Driver::Stats.dump_stats }
  signal.ignore
end
