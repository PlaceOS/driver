require "./helper"

describe PlaceOS::Driver::Log do
  it "should send outgoing requests" do
    proto, _, output = Helper.protocol
    std_out = IO::Memory.new

    # By default debug messages are ignored
    logger = PlaceOS::Driver::Log.new("mod-123", std_out, protocol: proto)
    logger.debug { "this should do nothing" }

    (std_out.size > 0).should eq(false)

    # However when debugging we want these to be routed to the developer
    logger.debugging = true
    logger.debug { "whatwhat" }

    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)
    req_out = PlaceOS::Driver::Protocol::Request.from_json(String.new(raw_data[2, bytes_read - 4]))
    req_out.id.should eq("mod-123")
    req_out.payload.should eq(%{[1,"whatwhat"]})

    # However we still don't want them being logged to our regular logs
    (std_out.size > 0).should eq(false)

    # Error and above logs should go to both
    logger.error { "hello-logs" }

    bytes_read = output.read(raw_data)
    req_out = PlaceOS::Driver::Protocol::Request.from_json(String.new(raw_data[2, bytes_read - 4]))
    req_out.id.should eq("mod-123")
    req_out.payload.should eq(%{[5,"hello-logs"]})

    (std_out.size > 10).should eq(true)
  end

  it "should send outgoing requests when blocks are used" do
    proto, _, output = Helper.protocol
    std_out = IO::Memory.new

    # By default debug messages are ignored
    logger = PlaceOS::Driver::Log.new("mod-123", std_out, proto)
    in_block = false
    logger.debug {
      in_block = true
      "this should do nothing"
    }

    in_block.should eq(false)
    (std_out.size > 0).should eq(false)

    # However when debugging we want these to be routed to the developer
    logger.debugging = true
    logger.debug {
      in_block = true
      "whatwhat"
    }

    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)
    req_out = PlaceOS::Driver::Protocol::Request.from_json(String.new(raw_data[2, bytes_read - 4]))
    req_out.id.should eq("mod-123")
    req_out.payload.should eq(%{[1,"whatwhat"]})

    # However we still don't want them being logged to our regular logs
    in_block.should eq(true)
    (std_out.size > 0).should eq(false)

    # Warning and above logs should go to both
    logger.error { "hello-logs" }

    bytes_read = output.read(raw_data)
    req_out = PlaceOS::Driver::Protocol::Request.from_json(String.new(raw_data[2, bytes_read - 4]))
    req_out.id.should eq("mod-123")
    req_out.payload.should eq(%{[5,"hello-logs"]})

    (std_out.size > 10).should eq(true)
  end
end
