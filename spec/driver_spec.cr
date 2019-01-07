require "./helper"

describe EngineDriver::Logger do
  it "should initialize a driver" do
    driver = Helper.new_driver(Helper::TestDriver, "mod-987")
    driver.is_a?(EngineDriver).should eq(true)
  end

  it "should initialize a concrete driver" do
    driver = Helper.new_driver({{EngineDriver::CONCRETE_DRIVERS.keys.first}}, "mod-999")
    driver.is_a?(EngineDriver).should eq(true)
  end
end
