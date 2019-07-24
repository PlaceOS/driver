module EngineDriver::Interface; end

module EngineDriver::Interface::Stoppable
  abstract def stop(index : Int32 | String = 0)
end
