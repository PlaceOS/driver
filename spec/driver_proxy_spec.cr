require "./helper"

describe EngineDriver::Proxy::Driver do
  it "indicate if a module / driver exists in a system" do
    cs = EngineDriver::DriverModel::ControlSystem.from_json(%(
        {
          "id": "sys-1236",
          "name": "Tesing System",
          "email": "name@email.com",
          "capacity": 20,
          "features": "in-house-pc projector",
          "bookable": true
        }
    ))

    system = EngineDriver::Proxy::System.new cs
    system.id.should eq("sys-1236")

    # Create a virtual systems
    storage = EngineDriver::Storage.new(cs.id, "system")
    storage["Display\x021"] = "mod-1234"
    system.exists?(:Display_1).should eq(true)

    # Create the driver metadata
    mod_store = EngineDriver::Storage.new("mod-1234")
    mod_store["power"] = false

    redis = EngineDriver::Storage.redis_pool
    meta = EngineDriver::DriverModel::Metadata.new({
        "function1" => {} of String => Array(String),
        "function2" => {"arg1" => ["Int32"]},
        "function3" => {"arg1" => ["Int32", "200"], "arg2" => ["Int32"]},
    }, ["Functoids"])
    redis.set("interface\x02mod-1234", meta.to_json)

    # Check if implements check works
    system[:Display_1].implements?(:function0).should eq(false)
    system[:Display_1].implements?(:function1).should eq(true)
    system[:Display_1].implements?(:Functoids).should eq(true)
    system[:Display_1].implements?(:RandomInterfaceNotLocal).should eq(false)

    # Grab the protocol output
    proto, _, output = Helper.protocol
    EngineDriver::Protocol.new_instance proto

    # Execute a remote function
    result = system[:Display_1].function1
    result.is_a?(Promise::DeferredPromise(JSON::Any))

    # Check the exec request
    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)
    req_out = EngineDriver::Protocol::Request.from_json(String.new(raw_data[4, bytes_read - 4]))
    req_out.payload.should eq(%({"__exec__":"function1","function1":{}}))

    # Attempt to execute a function that doesn't exist
    result = system[:Display_1].function8
    result.is_a?(Promise::DeferredPromise(JSON::Any))

    expect_raises(Exception) do
      result.get
    end

    # Attept to execute a function with invalid arguments
    result = system[:Display_1].function2
    result.is_a?(Promise::DeferredPromise(JSON::Any))

    expect_raises(Exception) do
      result.get
    end

    # Execute a remote function with arguments
    result = system[:Display_1].function2(12345)
    result.is_a?(Promise::DeferredPromise(JSON::Any))

    # Check the exec request
    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)
    req_out = EngineDriver::Protocol::Request.from_json(String.new(raw_data[4, bytes_read - 4]))
    req_out.payload.should eq(%({"__exec__":"function2","function2":{"arg1":12345}}))

    # Execute a remote function with named arguments
    result = system[:Display_1].function3(arg2: 12345)
    result.is_a?(Promise::DeferredPromise(JSON::Any))

    # Check the exec request
    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)
    req_out = EngineDriver::Protocol::Request.from_json(String.new(raw_data[4, bytes_read - 4]))
    req_out.payload.should eq(%({"__exec__":"function3","function3":{"arg1":null,"arg2":12345}}))

    redis.del("interface\x02mod-1234")
    mod_store.delete("power")
    storage.delete "Display\x021"
  end

  it "should subscribe to status updates" do
    cs = EngineDriver::DriverModel::ControlSystem.from_json(%(
        {
          "id": "sys-1234",
          "name": "Tesing System",
          "email": "name@email.com",
          "capacity": 20,
          "features": "in-house-pc projector",
          "bookable": true
        }
    ))

    subs = EngineDriver::Proxy::Subscriptions.new
    system = EngineDriver::Proxy::System.new cs
    # Create some virtual systems
    storage = EngineDriver::Storage.new(cs.id, "system")
    storage["Display\x021"] = "mod-1234"

    redis = EngineDriver::Storage.redis_pool
    in_callback = false
    sub_passed = nil
    message_passed = nil
    channel = Channel(Nil).new

    mod_store = EngineDriver::Storage.new("mod-1234")
    mod_store.delete("power")

    subscription = system[:Display_1].subscribe(:power) do |sub, value|
      sub_passed = sub
      message_passed = value
      in_callback = true
      channel.close
    end

    # Subscription should not exist yet - i.e. no lookup
    subscription.module_id.should eq("mod-1234")
    sleep 0.05

    # Update the status
    mod_store["power"] = true
    channel.receive?

    in_callback.should eq(true)
    message_passed.should eq("true")
    sub_passed.should eq(subscription)

    # Test ability to access module state
    system[:Display_1]["power"].as_bool == true

    subs.terminate
    mod_store.delete("power")
    storage.delete "Display\x021"
  end
end
