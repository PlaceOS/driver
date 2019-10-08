module ACAEngine::Driver::Interface; end

module ACAEngine::Driver::Interface::Stoppable
  abstract def stop(index : Int32 | String = 0, emergency : Bool = false)
end
