require "./helper"

describe PlaceOS::Driver::TransportSSH do
  it "should work with a received function" do
    pending!("spec only available in CI") unless ENV["CI"]?

    queue = Helper.queue
    transport = PlaceOS::Driver::TransportSSH.new(queue, "sshtest", 22, ::PlaceOS::Driver::Settings.new(%({
      "ssh": {
        "username": "root",
        "password": "somepassword"
      }
    }))) do |data, task|
      # This would usually call: driver.received(data, task)
      response = IO::Memory.new(data).to_s
      puts "ssh-sent: #{response}"
      task.try &.success(response) if response.includes?("USER")
    end

    transport.connect
    queue.online.should eq(true)

    task = queue.add { transport.send("ps aux\n") }.response_required!
    task.get.payload.includes?("USER").should eq(true)

    # Close the connection
    transport.terminate
  end
end
