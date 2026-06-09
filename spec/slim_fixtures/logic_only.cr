require "../../src/placeos-driver"

# a driver with no transport discovery settings is logic only
class Fixtures::LogicOnly < PlaceOS::Driver
  generic_name :LogicOnly
  descriptive_name "Logic only driver"

  def state(level : Bool)
    self[:state] = level
  end
end
