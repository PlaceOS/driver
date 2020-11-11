require "./helper"
require "../src/placeos-driver/protocol/management"

# build a driver
`crystal build ./spec/test_build.cr`

describe PlaceOS::Driver::Protocol::Management do
  it "should launch and manage an placeos driver process" do
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
        "features": ["in-house-pc","projector"],
        "bookable": true
      }
    }))
    manager.running?.should eq(true)

    # Called when the driver interacts with redis
    redis_callback = 0
    manager.on_redis = ->(is_status : PlaceOS::Driver::Protocol::Management::RedisAction, module_id : String, key_name : String, status_value : String?) {
      redis_callback += 1
    }

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

    logged.should eq(%([2,"testing info message"]))

    manager.info.should eq(["mod-management-test"])

    manager.stop("mod-management-test")
    sleep 0.2
    manager.running?.should eq(false)
    manager.terminated?.should eq(false)
    redis_callback.should eq 0
  end

  it "should launch and manage an placeos edge driver process" do
    # manage that driver
    manager = PlaceOS::Driver::Protocol::Management.new("./test_build", on_edge: true)
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
        "features": ["in-house-pc","projector"],
        "bookable": true
      }
    }))
    manager.running?.should eq(true)

    # Called when the driver interacts with redis
    redis_callback = 0
    manager.on_redis = ->(is_status : PlaceOS::Driver::Protocol::Management::RedisAction, module_id : String, key_name : String, status_value : String?) {
      redis_callback += 1
    }

    # Named params
    manager.execute("mod-management-test", %({
      "__exec__": "add",
      "add": {
        "a": 1,
        "b": 2
      }
    })).should eq("3")

    redis_callback.should eq 1

    # Regular arguments
    manager.execute("mod-management-test", %({
      "__exec__": "add",
      "add": [1, 2]
    })).should eq("3")

    # Status shouldn't have changed, so we only expect this to be 1
    redis_callback.should eq 1

    logged = nil
    manager.debug("mod-management-test") do |debug_json|
      logged = debug_json
    end

    manager.execute("mod-management-test", %({
      "__exec__": "implemented_in_base_class",
      "implemented_in_base_class": {}
    }))

    logged.should eq(%([2,"testing info message"]))

    manager.info.should eq(["mod-management-test"])

    manager.stop("mod-management-test")
    sleep 0.2
    manager.running?.should eq(false)
    manager.terminated?.should eq(false)
  end
end
