require "./helper"

describe PlaceOS::Driver::DriverManager do
  it "should initialize a driver" do
    driver = Helper.new_driver(Helper::TestDriver, "mod-987", Helper.protocol[0])
    driver.is_a?(PlaceOS::Driver).should eq(true)
  end

  it "should initialize a concrete driver and execute on it" do
    driver = Helper.new_driver({{PlaceOS::Driver::CONCRETE_DRIVERS.keys.first}}, "mod-999", Helper.protocol[0])
    driver.is_a?(PlaceOS::Driver).should eq(true)

    executor = {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.new(%(
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
    executor = {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.new(%(
        {
          "__exec__": "add",
          "add": [2, 3]
        }
    ))
    executor.execute(driver).should eq("5")

    executor = {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.new(%(
        {
          "__exec__": "splat_add",
          "splat_add": {}
        }
    ))
    executor.execute(driver).should eq("0")

    # Test an enum heavy function
    executor = {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.new(%(
        {
          "__exec__": "switch_input",
          "switch_input": {"input": "DisplayPort"}
        }
    ))
    executor.execute(driver).should eq(%("DisplayPort"))

    {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.functions.should eq(%({
      "switch_input":{
        "input":[{"type":"string","enum":["hdmi","display_port","hd_base_t"],"title":"Helper::TestDriver::Input"}]
      },
      "add":{
        "a":[{"type":"integer","title":"Int32"}],
        "b":[{"type":"integer","title":"Int32"}]
      },
      "splat_add":{},
      "perform_task":{
        "name":[{"anyOf":[{"type":"integer"},{"type":"string"}],"title":"(Int32 | String)"}]
      },
      "error_task":{},
      "future_add":{
        "a":[{"type":"integer","title":"Int32"}],
        "b":[{"type":"integer","title":"Int32","default":200}, 200]
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
    PlaceOS::Driver::Protocol.new_instance(Helper.protocol[0]) unless PlaceOS::Driver::Protocol.instance?
    model = PlaceOS::Driver::DriverModel.from_json(%({
      "ip": "localhost",
      "port": 23,
      "udp": false,
      "tls": false,
      "makebreak": false,
      "role": 1,
      "settings": {"test": {"number": 123}}
    }))
    PlaceOS::Driver::DriverManager.new "mod-driverman", model
  end
end
