require "./helper"
require "../src/driver/protocol/management"

describe PlaceOS::Driver::Protocol::Management do
  it "should launch and manage an placeos driver process" do
    # build a driver
    `crystal build ./spec/test_build.cr`

    # manage that driver
    manager = PlaceOS::Driver::Protocol::Management.new("./test_build")
    manager.running?.should eq(false)

    # Launch an instance of the driver
    manager.start("mod-management-test", %({
      "ip": "localhost",
      "port": 23,
      "udp": false,
      "tls": false,
      "makebreak": false,
      "role": 99,
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

    # Named params
    manager.execute("mod-management-test", %({
      "__exec__": "add",
      "add": {
        "a": 1,
        "b": 2
      }
    })).should eq("3")

    # Regular arguments
    manager.execute("mod-management-test", %({
      "__exec__": "add",
      "add": [1, 2]
    })).should eq("3")

    logged = nil
    manager.debug("mod-management-test") do |debug_json|
      logged = debug_json
    end

    manager.execute("mod-management-test", %({
      "__exec__": "implemented_in_base_class",
      "implemented_in_base_class": {}
    }))

    logged.should eq(%([1,"testing info message"]))

    manager.info.should eq(["mod-management-test"])

    manager.stop("mod-management-test")
    sleep 0.2
    manager.running?.should eq(false)
    manager.terminated.should eq(false)
  end
end
