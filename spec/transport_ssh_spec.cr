require "./helper"

describe PlaceOS::Driver::TransportSSH do
  it "should work with a received function" do
    pending!("spec only available in CI") unless ENV["CI"]?

    queue = Helper.queue
    count = 0
    transport = PlaceOS::Driver::TransportSSH.new(queue, "sshtest", 2222, ::PlaceOS::Driver::Settings.new(%({
      "ssh": {
        "username": "root",
        "password": "somepassword"
      }
    }))) do |data, task|
      # This would usually call: driver.received(data, task)
      response = IO::Memory.new(data).to_s
      count += 1
      task.try &.success(response) if count >= 3 && !response.includes?("root@")
    end

    transport.connect
    queue.online.should eq(true)

    task = queue.add { transport.send("ps aux\n") }.response_required!
    task.get.payload.includes?("USER").should eq(true)

    # Close the connection
    transport.terminate
  end
end
