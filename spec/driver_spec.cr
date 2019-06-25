require "./helper"

describe EngineDriver::DriverManager do
  it "should initialize a driver" do
    driver = Helper.new_driver(Helper::TestDriver, "mod-987", Helper.protocol[0])
    driver.is_a?(EngineDriver).should eq(true)
  end

  it "should initialize a concrete driver and execute on it" do
    driver = Helper.new_driver({{EngineDriver::CONCRETE_DRIVERS.keys.first}}, "mod-999", Helper.protocol[0])
    driver.is_a?(EngineDriver).should eq(true)

    executor = {{EngineDriver::CONCRETE_DRIVERS.values.first[1]}}.from_json(%(
        {
          "__exec__": "add",
          "add": {
            "a": 1,
            "b": 2
          }
        }
    ))
    executor.execute(driver).should eq(3)

    executor = {{EngineDriver::CONCRETE_DRIVERS.values.first[1]}}.from_json(%(
        {
          "__exec__": "splat_add",
          "splat_add": {}
        }
    ))
    executor.execute(driver).should eq(0)

    {{EngineDriver::CONCRETE_DRIVERS.values.first[1]}}.functions.should eq(%({
      "add":{
        "a":["Int32"],
        "b":["Int32"]
      },
      "splat_add":{},
      "perform_task":{
        "name":["String"]
      },
      "error_task":{},
      "future_add":{
        "a":["Int32"],
        "b":["Int32","200"]
      },
      "future_error":{},
      "raise_error":{},
      "not_json":{},
      "test_http":{},
      "test_exec":{},
      "implemented_in_base_class":{}
    }).gsub(/\s/, ""))
  end

  it "should initialize an instance of driver manager" do
    EngineDriver::Protocol.new_instance(Helper.protocol[0]) unless EngineDriver::Protocol.instance?
    model = EngineDriver::DriverModel.from_json(%({
      "ip": "localhost",
      "port": 23,
      "udp": false,
      "tls": false,
      "makebreak": false,
      "role": 1,
      "settings": {"test": {"number": 123}}
    }))
    EngineDriver::DriverManager.new "mod-driverman", model
  end
end
