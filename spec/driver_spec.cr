require "./helper"

describe EngineDriver::Logger do
  it "should initialize a driver" do
    driver = Helper.new_driver(Helper::TestDriver, "mod-987")
    driver.is_a?(EngineDriver).should eq(true)
  end

  it "should initialize a concrete driver and execute on it" do
    driver = Helper.new_driver({{EngineDriver::CONCRETE_DRIVERS.keys.first}}, "mod-999")
    driver.is_a?(EngineDriver).should eq(true)

    executor = {{EngineDriver::CONCRETE_DRIVERS.values.first}}.from_json(%(
        {
          "__exec__": "add",
          "add": {
            "a": 1,
            "b": 2
          }
        }
    ))
    executor.execute(driver).should eq(3)

    executor = {{EngineDriver::CONCRETE_DRIVERS.values.first}}.from_json(%(
        {
          "__exec__": "splat_add",
          "splat_add": {}
        }
    ))
    executor.execute(driver).should eq(0)

    {{EngineDriver::CONCRETE_DRIVERS.values.first}}.functions.should eq(%({"add":{"a":"Int32","b":"Int32"},"splat_add":{}}))
  end
end
