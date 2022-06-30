require "gc"

module PlaceOS::Driver::Stats
  Log = ::Log.for(self)

  def self.dump_stats
    stats = GC.stats
    one_mib = 1048576
    Log.warn { "\n\nMemory Usage:\n - Free: #{(stats.free_bytes / one_mib).round(1)}MiB\n - Heap: #{(stats.heap_size / one_mib).round(1)}MiB\n - Total: #{(stats.total_bytes / one_mib).round(1)}MiB\n - Unmapped #{(stats.unmapped_bytes / one_mib).round(1)}MiB\n\n" }
  end

  def self.setup_signal
    Signal::USR2.trap do |signal|
      spawn { PlaceOS::Driver::Stats.dump_stats }
      signal.ignore
      setup_signal
    end
  end
end

PlaceOS::Driver::Stats.setup_signal
