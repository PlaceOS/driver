require "./helper"

describe PlaceOS::Driver::Proxy::Driver do
  it "should execute functions on remote drivers" do
    cs = PlaceOS::Driver::DriverModel::ControlSystem.from_json(%(
        {
          "id": "sys-1236",
          "name": "Tesing System",
          "email": "name@email.com",
          "capacity": 20,
          "features": "in-house-pc projector",
          "bookable": true
        }
    ))

    system = PlaceOS::Driver::Proxy::System.new cs, "reply_id"
    system.id.should eq("sys-1236")

    # Create a virtual systems
    storage = PlaceOS::Driver::Storage.new(cs.id, "system")
    storage["Display/1"] = "mod-1234"
    system.exists?(:Display_1).should eq(true)

    # Create the driver metadata
    mod_store = PlaceOS::Driver::Storage.new("mod-1234")
    mod_store["power"] = false

    redis = PlaceOS::Driver::Storage.redis_pool
    meta = PlaceOS::Driver::DriverModel::Metadata.new({
      "function1" => {} of String => Array(String),
      "function2" => {"arg1" => ["Int32"]},
      "function3" => {"arg1" => ["Int32", "200"], "arg2" => ["Int32"]},
    }, ["Functoids"])
    redis.set("interface/mod-1234", meta.to_json)

    # Check if implements check works
    system[:Display_1].implements?(:function0).should eq(false)
    system[:Display_1].implements?(:function1).should eq(true)
    system[:Display_1].implements?(:Functoids).should eq(true)
    system[:Display_1].implements?(:RandomInterfaceNotLocal).should eq(false)

    # Grab the protocol output
    proto, input, output = Helper.protocol
    PlaceOS::Driver::Protocol.new_instance proto

    # Execute a remote function
    result = system[:Display_1].function1
    result.is_a?(Concurrent::Future(JSON::Any)).should eq(true)

    # Check the exec request
    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)
    req_out = PlaceOS::Driver::Protocol::Request.from_json(String.new(raw_data[4, bytes_read - 4]))
    req_out.payload.should eq(%({"__exec__":"function1","function1":{}}))
    req_out.reply.should eq("reply_id")
    req_out.id.should eq("mod-1234")

    # reply to the execute request
    req_out.cmd = "result"
    req_out.payload = "12345"
    json_resp = req_out.to_json
    input.write_bytes json_resp.bytesize
    input.write json_resp.to_slice

    result.get.should eq(12345)

    # Attempt to execute a function that doesn't exist
    result = system[:Display_1].function8
    result.is_a?(Concurrent::Future(JSON::Any)).should eq(true)

    expect_raises(Exception) do
      result.get
    end

    # Attempt to execute a function with invalid arguments
    result = system[:Display_1].function2
    result.is_a?(Concurrent::Future(JSON::Any)).should eq(true)

    expect_raises(Exception) do
      result.get
    end

    # Execute a remote function with arguments
    result = system[:Display_1].function2(12_345)
    result.is_a?(Concurrent::Future(JSON::Any)).should eq(true)

    # Check the exec request
    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)
    req_out = PlaceOS::Driver::Protocol::Request.from_json(String.new(raw_data[4, bytes_read - 4]))
    req_out.payload.should eq(%({"__exec__":"function2","function2":{"arg1":12345}}))

    # Execute a remote function with named arguments
    result = system[:Display_1].function3(arg2: 12_345)
    result.is_a?(Concurrent::Future(JSON::Any)).should eq(true)

    # Check the exec request
    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)
    req_out = PlaceOS::Driver::Protocol::Request.from_json(String.new(raw_data[4, bytes_read - 4]))
    req_out.payload.should eq(%({"__exec__":"function3","function3":{"arg1":null,"arg2":12345}}))

    # Ensure timeouts work!!
    result = system[:Display_1].function1
    result.is_a?(Concurrent::Future(JSON::Any)).should eq(true)

    # Check the exec request
    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)
    req_out = PlaceOS::Driver::Protocol::Request.from_json(String.new(raw_data[4, bytes_read - 4]))
    req_out.payload.should eq(%({"__exec__":"function1","function1":{}}))
    req_out.reply.should eq("reply_id")
    req_out.id.should eq("mod-1234")

    sleep 0.5

    # reply to the execute request
    req_out.cmd = "result"
    req_out.payload = "12345"
    json_resp = req_out.to_json
    input.write_bytes json_resp.bytesize
    input.write json_resp.to_slice

    expect_raises(PlaceOS::Driver::RemoteException) do
      result.get
    end

    # CLEAN UP
    redis.del("interface/mod-1234")
    mod_store.clear
    storage.clear
  end

  it "should subscribe to status updates" do
    cs = PlaceOS::Driver::DriverModel::ControlSystem.from_json(%(
        {
          "id": "sys-1234",
          "name": "Tesing System",
          "email": "name@email.com",
          "capacity": 20,
          "features": "in-house-pc projector",
          "bookable": true
        }
    ))

    subs = PlaceOS::Driver::Proxy::Subscriptions.new
    system = PlaceOS::Driver::Proxy::System.new cs, "reply_id"
    # Create some virtual systems
    storage = PlaceOS::Driver::Storage.new(cs.id, "system")
    storage["Display/1"] = "mod-1234"

    in_callback = false
    sub_passed = nil
    message_passed = nil
    channel = Channel(Nil).new

    mod_store = PlaceOS::Driver::Storage.new("mod-1234")
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
    system[:Display_1].status(Bool, "power") == true

    subs.terminate
    mod_store.clear
    storage.clear
  end
end
