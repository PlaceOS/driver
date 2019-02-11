require "./helper"

describe EngineDriver::TransportSSH do
  it "should work with a received function" do
    queue = Helper.queue
    count = 0
    transport = EngineDriver::TransportSSH.new(queue, "localhost", 2222, ::EngineDriver::Settings.new(%({
      "ssh": {
        "username": "root",
        "password": "somepassword"
      }
    }))) do |data, task|
      # This would usually call: driver.received(data, task)
      response = IO::Memory.new(data).to_s
      count += 1
      task.try &.success(response) if count == 3
    end

    transport.connect
    queue.online.should eq(true)

    task = queue.add { transport.send("ls /\n") }.response_required!
    task.get.payload.includes?("bin").should eq(true)

    # Close the connection
    transport.terminate
  end
end
