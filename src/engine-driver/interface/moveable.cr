module EngineDriver::Interface; end

module EngineDriver::Interface::Moveable
  enum MoveablePosition
    Open
    Close
    Up
    Down
    Left
    Right
    In
    Out
  end

  abstract def move(position : MoveablePosition, index : Int32 | String = 0)
end
