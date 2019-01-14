require "./helper"

describe EngineDriver::Utilities do
  it "should send a WOL packet" do
    server = UDPSocket.new
    server.bind "0.0.0.0", 1234

    EngineDriver::Utilities.wake_device("f0:18:98:25:bd:4f", port: 1234)

    raw_data = Bytes.new(2048)
    bytes_read = server.read(raw_data)
    data = raw_data[0, bytes_read]
    server.close

    data.hexstring.should eq("fffffffffffff0189825bd4ff0189825bd4ff0189825bd4ff0189825bd4ff0189825bd4ff0189825bd4ff0189825bd4ff0189825bd4ff0189825bd4ff0189825bd4ff0189825bd4ff0189825bd4ff0189825bd4ff0189825bd4ff0189825bd4ff0189825bd4f")
  end
end
