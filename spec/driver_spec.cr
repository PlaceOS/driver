require "./helper"

describe ACAEngine::Driver::DriverManager do
  it "should initialize a driver" do
    driver = Helper.new_driver(Helper::TestDriver, "mod-987", Helper.protocol[0])
    driver.is_a?(ACAEngine::Driver).should eq(true)
  end

  it "should initialize a concrete driver and execute on it" do
    driver = Helper.new_driver({{ACAEngine::Driver::CONCRETE_DRIVERS.keys.first}}, "mod-999", Helper.protocol[0])
    driver.is_a?(ACAEngine::Driver).should eq(true)

    executor = {{ACAEngine::Driver::CONCRETE_DRIVERS.values.first[1]}}.new(%(
        {
          "__exec__": "add",
          "add": {
            "a": 1,
            "b": 2
          }
        }
    ))
    executor.execute(driver).should eq("3")

    # Check that argument arrays can be accepted too
    executor = {{ACAEngine::Driver::CONCRETE_DRIVERS.values.first[1]}}.new(%(
        {
          "__exec__": "add",
          "add": [2, 3]
        }
    ))
    executor.execute(driver).should eq("5")

    executor = {{ACAEngine::Driver::CONCRETE_DRIVERS.values.first[1]}}.new(%(
        {
          "__exec__": "splat_add",
          "splat_add": {}
        }
    ))
    executor.execute(driver).should eq("0")

    # Test an enum heavy function
    executor = {{ACAEngine::Driver::CONCRETE_DRIVERS.values.first[1]}}.new(%(
        {
          "__exec__": "switch_input",
          "switch_input": {"input": "DisplayPort"}
        }
    ))
    executor.execute(driver).should eq(%("DisplayPort"))

    {{ACAEngine::Driver::CONCRETE_DRIVERS.values.first[1]}}.functions.should eq(%({
      "switch_input":{
        "input":["String"]
      },
      "add":{
        "a":["Int32"],
        "b":["Int32"]
      },
      "splat_add":{},
      "perform_task":{
        "name":["String | Int32"]
      },
      "error_task":{},
      "future_add":{
        "a":["Int32"],
        "b":["Int32", 200]
      },
      "future_error":{},
      "raise_error":{},
      "not_json":{},
      "test_http":{},
      "test_exec":{},
      "implemented_in_base_class":{}
    }).gsub(/\s/, "").gsub(/\|/, " | "))
  end

  it "should initialize an instance of driver manager" do
    ACAEngine::Driver::Protocol.new_instance(Helper.protocol[0]) unless ACAEngine::Driver::Protocol.instance?
    model = ACAEngine::Driver::DriverModel.from_json(%({
      "ip": "localhost",
      "port": 23,
      "udp": false,
      "tls": false,
      "makebreak": false,
      "role": 1,
      "settings": {"test": {"number": 123}}
    }))
    ACAEngine::Driver::DriverManager.new "mod-driverman", model
  end
end
