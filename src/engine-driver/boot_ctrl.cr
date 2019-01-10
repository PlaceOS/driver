class EngineDriver
  class BootCtrl
    @@auto_start = true

    def self.auto_start=(state)
      @@auto_start = state
    end

    def self.auto_start
      @@auto_start
    end
  end
end
