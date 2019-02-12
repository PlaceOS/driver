require "./helper"

describe EngineDriver::Proxy::Drivers do
  it "should execute functions on collections of remote drivers" do
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

    system = EngineDriver::Proxy::System.new cs, "reply_id"
    system.id.should eq("sys-1236")

    # Create a virtual systems
    storage = EngineDriver::Storage.new(cs.id, "system")
    storage.clear
    storage["Display\x021"] = "mod-999"
    storage["Display\x022"] = "mod-888"
    storage["Switcher\x021"] = "mod-444"
    storage.size.should eq(3)
    storage.empty?.should eq(false)
    system.exists?(:Display_1).should eq(true)
    system.exists?(:Display_2).should eq(true)

    # Create the driver metadata
    redis = EngineDriver::Storage.redis_pool
    meta = EngineDriver::DriverModel::Metadata.new({
      "function1" => {} of String => Array(String),
      "function2" => {"arg1" => ["Int32"]},
      "function3" => {"arg1" => ["Int32", "200"], "arg2" => ["Int32"]},
    }, ["Functoids"])
    redis.set("interface\x02mod-999", meta.to_json)
    redis.set("interface\x02mod-888", meta.to_json)

    meta = EngineDriver::DriverModel::Metadata.new({
      "function1" => {} of String => Array(String),
    })
    redis.set("interface\x02mod-444", meta.to_json)

    # Check if implements check works
    system.modules.should eq(["Display", "Switcher"])
    system.all(:Display).size.should eq(2)
    system.all(:Switcher).size.should eq(1)
    system.all(:Booking).size.should eq(0)
    system.all(:Display).implements?(:function0).should eq(false)
    system.all(:Display).implements?(:function1).should eq(true)
    system.all(:Display).implements?(:Functoids).should eq(true)
    system.all(:Display).implements?(:RandomInterfaceNotLocal).should eq(false)

    system.implementing(:function1).size.should eq(3)
    system.implementing(:function2).size.should eq(2)
    system.implementing(:Functoids).size.should eq(2)

    # Check if enumeration works
    count = 0
    system.all(:Display).each { |driver| driver.module_name; count += 1 }
    count.should eq(2)

    system.all(:Display).each_with_index { |_, index| count = index }
    count.should eq(1)

    # Grab the protocol output
    proto, _, output = Helper.protocol
    EngineDriver::Protocol.new_instance proto

    # Execute a remote function
    result = system.all(:Display).function1
    result.is_a?(EngineDriver::Proxy::Drivers::Responses).should eq(true)

    # Check the exec request
    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)
    tokenizer = ::Tokenizer.new do |io|
      begin
        io.read_bytes(Int32) + 4
      rescue
        0
      end
    end
    messages = tokenizer.extract(raw_data[0, bytes_read])

    message = messages[0]
    req_out = EngineDriver::Protocol::Request.from_json(String.new(message[4, message.bytesize - 4]))
    req_out.payload.should eq(%({"__exec__":"function1","function1":{}}))
    req_out.id.should eq("mod-999")
    req_out.reply.should eq("reply_id")

    message = messages[1]
    req_out = EngineDriver::Protocol::Request.from_json(String.new(message[4, message.bytesize - 4]))
    req_out.payload.should eq(%({"__exec__":"function1","function1":{}}))
    req_out.id.should eq("mod-888")
    req_out.reply.should eq("reply_id")

    storage.clear
  end
end
