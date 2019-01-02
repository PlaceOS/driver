require "./helper"

describe EngineDriver::TransportTCP do
  it "should work with a received function" do
    Helper.tcp_server

    queue = Helper.queue
    transport = EngineDriver::TransportTCP.new(queue, "localhost", 1234) do |data, task|
      # This would usually call: driver.received(data, task)
      response = IO::Memory.new(data).to_s
      task.try &.success(response)
    end

    #driver = Helper::TestDriver.new(queue, transport)
    #transport.driver = driver
    transport.connect

    queue.online.should eq(true)

    task = queue.add { transport.send("test\n") }.response_required!
    task.get[:payload].should eq("[\"test\"]")

    # Close the connection
    transport.terminate
  end

  it "should work with a callback" do
    Helper.tcp_server

    queue = Helper.queue
    transport = EngineDriver::TransportTCP.new(queue, "localhost", 1234) do |data, task|
      # This would usually call: driver.received(data, task)
      response = IO::Memory.new(data).to_s
      task.try &.success(response)
    end

    # driver = Helper::TestDriver.new(queue, transport)
    # transport.driver = driver
    transport.connect

    queue.online.should eq(true)

    in_callback = false
    task = queue.add do |req|
      transport.send("test\n", req) do |data|
        in_callback = true
        response = IO::Memory.new(data).to_s
        req.try &.success(response)
      end
    end
    task.response_required!
    task.get[:payload].should eq("[\"test\"]")
    in_callback.should eq(true)

    # Close the connection
    transport.terminate
  end
end
