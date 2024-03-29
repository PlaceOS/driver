abstract class PlaceOS::Driver
  # Expects status of the movable object to be defined as
  # position{index} = Open / Close / Up / Down etc
  # i.e. self[:position0] = MoveablePosition::Open
  # (optional) self[moving0] = true / false
  module Interface::Moveable
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
end
