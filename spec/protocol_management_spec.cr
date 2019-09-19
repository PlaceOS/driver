require "./helper"
require "../src/engine-driver/protocol/management"

describe EngineDriver::Protocol::Management do
  it "should launch and manage an engine driver process" do
    # build a driver
    `crystal build ./spec/test_build.cr`

    # manage that driver
    manager = EngineDriver::Protocol::Management.new("./test_build")
    manager.running?.should eq(false)

    # Launch an instance of the driver
    manager.start("mod-management-test", %({
      "ip": "localhost",
      "port": 23,
      "udp": false,
      "tls": false,
      "makebreak": false,
      "role": 3,
      "settings": {"test": {"number": 123}},
      "control_system": {
        "id": "sys-1234",
        "name": "Tesing System",
        "email": "name@email.com",
        "capacity": 20,
        "features": "in-house-pc projector",
        "bookable": true
      }
    }))
    manager.running?.should eq(true)

    manager.execute("mod-management-test", %({
      "__exec__": "add",
      "add": {
        "a": 1,
        "b": 2
      }
    })).should eq("3")

    manager.stop("mod-management-test")
    sleep 0.2
    manager.running?.should eq(false)
    manager.terminated.should eq(false)
  end
end
