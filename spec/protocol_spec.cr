require "./helper"

describe PlaceOS::Driver::Protocol do
  it "should parse an incomming request" do
    proto, input, _ = Helper.protocol

    id = nil
    PlaceOS::Driver::ProcessManagerMock.register "start" do |request|
      id = request.id
      input.close
      nil
    end

    json = {id: "mod_1234", cmd: "start", payload: "{\"settings\":1234}"}.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    while id.nil?
      sleep 10.milliseconds
    end

    id.should eq("mod_1234")
  end

  it "should send outgoing requests" do
    proto, _, output = Helper.protocol
    req = proto.request("sys-abcd", :exec, {mod: "Display_1"})

    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)
    req_out = PlaceOS::Driver::Protocol::Request.from_json(String.new(raw_data[2, bytes_read - 4]))
    req_out.id.should eq(req.id)
  end

  it "should handle back to back requests" do
    proto, input, _ = Helper.protocol

    results = [] of String
    PlaceOS::Driver::ProcessManagerMock.register "start" do |request|
      results << request.id.not_nil!
      nil
    end

    io = IO::Memory.new
    json = {id: "mod_1234", cmd: "start", payload: "{\"settings\":1234}"}.to_json
    io.write_bytes json.bytesize
    io.write json.to_slice
    json = {id: "mod_5678", cmd: "start", payload: "{\"settings\":othereeeee}"}.to_json
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.rewind

    IO.copy(io, input)

    while results.size < 2
      sleep 10.milliseconds
    end

    input.close
    results.should eq(["mod_1234", "mod_5678"])
  end
end
