require "./helper"
require "../src/placeos-driver/protocol/management"

# build a driver
`crystal build ./spec/test_build.cr`

describe PlaceOS::Driver::Protocol::Management do
  it "should launch and manage an placeos driver process" do
    # manage that driver
    manager = PlaceOS::Driver::Protocol::Management.new("./test_build")
    manager.running?.should eq(false)

    # Called when the driver interacts with redis
    redis_callback = 0
    manager.on_redis = ->(_is_status : PlaceOS::Driver::Protocol::Management::RedisAction, _module_id : String, _key_name : String, _status_value : String?) {
      redis_callback += 1
    }

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
        "bookable": true,
        "zones": ["zone-1234"]
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
    })).should eq({"3", 200})

    # Regular arguments
    manager.execute("mod-management-test", %({
      "__exec__": "add",
      "add": [1, 2]
    })).should eq({"3", 200})

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

    # Called when the driver interacts with redis
    redis_set = 0
    redis_hset = 0
    redis_clear = 0
    redis_publish = 0
    manager.on_redis = ->(action : PlaceOS::Driver::Protocol::Management::RedisAction, hash : String, key : String, value : String?) {
      puts "\n#{hash} -> #{key} -> #{value}\n"

      case action
      in .set?     then redis_set += 1
      in .hset?    then redis_hset += 1
      in .clear?   then redis_clear += 1
      in .publish? then redis_publish += 1
      end
    }

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
        "bookable": true,
        "zones": ["zone-1234"]
      }
    }))
    manager.running?.should eq(true)

    sleep 0.5

    # Clears the module state
    redis_clear.should eq 1
    # Sets the function list metadata
    redis_set.should eq 1
    # Connected status
    redis_hset.should eq 1

    # Nothing should be published
    redis_publish.should eq 0

    # Named params
    manager.execute("mod-management-test", %({
      "__exec__": "add",
      "add": {
        "a": 1,
        "b": 2
      }
    })).should eq({"3", 200})

    redis_hset.should eq 2

    # Regular arguments
    manager.execute("mod-management-test", %({
      "__exec__": "add",
      "add": [1, 2]
    })).should eq({"3", 200})

    # Status shouldn't have changed, so we only expect this to be 1
    redis_hset.should eq 2

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
