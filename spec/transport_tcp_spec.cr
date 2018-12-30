require "./helper"

describe EngineDriver::TransportTCP do
  it "should initialize a TCP transport" do
    Helper.tcp_server

    queue = Helper.queue
    transport = EngineDriver::TransportTCP.new(queue, "localhost", 1234)
    driver = Helper::TestDriver.new(queue, transport)
    transport.driver = driver
    transport.connect

    queue.online.should eq(true)

    task = queue.add { transport.send("test\n") }.response_required!
    task.get[:payload].should eq("[\"test\"]")

    # Close the connection
    transport.terminate
  end
end
