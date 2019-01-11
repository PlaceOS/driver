require "./helper"

describe EngineDriver::ProcessManager do

  # * Start
  # * Execute (simple) + response
  # * Enable debugging
  # * Disable debugging
  # * Update settings
  # * Stop driver
  # * Terminate
  it "should start and stop a process without issue" do
    process, input, output, logs, driver_id = Helper.process
    process.loaded.size.should eq 1

    # execute a simple request (not a task response)
    json = {
      id: driver_id,
      cmd: "exec",
      payload: %({
        "__exec__": "add",
        "add": {
          "a": 1,
          "b": 2
        }
      })
    }.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    sleep 0.01
    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)

    # Check response was returned
    req_out = EngineDriver::Protocol::Request.from_json(String.new(raw_data[4, bytes_read - 4]))
    req_out.id.should eq(driver_id)
    req_out.cmd.should eq("result")
    req_out.payload.should eq("3")

    # Enable debugging
    json = {
      id: driver_id,
      cmd: "debug"
    }.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    process.loaded[driver_id].logger.debugging.should eq(false)
    sleep 0.01
    process.loaded[driver_id].logger.debugging.should eq(true)

    # Disable debugging
    json = {
      id: driver_id,
      cmd: "ignore"
    }.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    process.loaded["mod_1234"].logger.debugging.should eq(true)
    sleep 0.01
    process.loaded["mod_1234"].logger.debugging.should eq(false)

    # Update settings
    json = {
      id: driver_id,
      cmd: "update",
      payload: %({"test": {"number": 1234}})
    }.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    process.loaded[driver_id].settings.json["test"]["number"].as_i.should eq(123)
    sleep 0.01
    process.loaded[driver_id].settings.json["test"]["number"].as_i.should eq(1234)

    # Stop a driver
    json = {
      id: driver_id,
      cmd: "stop"
    }.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    process.loaded.size.should eq 1
    sleep 0.01
    process.loaded.size.should eq 0

    # Ensure it terminates properly
    json = {
      id: "t",
      cmd: "terminate"
    }.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    process.terminated.receive?
    process.loaded.size.should eq 0
  end

  # * Start
  # * Execute and raise an error + response
  # * Execute and return a non-json object + response
  # * Update with invalid settings
  # * Terminate
  it "should handle errors gracefully" do
    process, input, output, logs, driver_id = Helper.process
    process.loaded.size.should eq 1

    # Execute something that errors
    json = {
      id: driver_id,
      cmd: "exec",
      payload: %({
        "__exec__": "raise_error",
        "raise_error": {}
      })
    }.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    sleep 0.01
    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)

    # Check response was returned
    req_out = EngineDriver::Protocol::Request.from_json(String.new(raw_data[4, bytes_read - 4]))
    req_out.id.should eq(driver_id)
    req_out.cmd.should eq("result")
    req_out.payload.should eq("you fool!")
    req_out.error.should eq("ArgumentError")
    (req_out.backtrace.not_nil!.size > 0).should eq(true)

    # Check error was logged
    raw_data = Bytes.new(4096)
    bytes_read = logs.read(raw_data)
    String.new(raw_data[4, bytes_read - 4]).includes?("you fool!").should eq(true)

    # Execute something that can't be serialised
    json = {
      id: driver_id,
      cmd: "exec",
      payload: %({
        "__exec__": "not_json",
        "not_json": {}
      })
    }.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    sleep 0.01
    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)

    # Check response was returned
    req_out = EngineDriver::Protocol::Request.from_json(String.new(raw_data[4, bytes_read - 4]))
    req_out.id.should eq(driver_id)
    req_out.cmd.should eq("result")
    req_out.payload.should eq("null")
    req_out.error.should eq(nil)
    req_out.backtrace.should eq(nil)

    # Ensure it terminates properly
    json = {
      id: "t",
      cmd: "terminate"
    }.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    process.loaded.size.should eq 1
    process.terminated.receive?
    process.loaded.size.should eq 0
  end

  it "should work with functions returning queue tasks" do
    process, input, output, logs, driver_id = Helper.process
    process.loaded.size.should eq 1

    # execute a task response
    json = {
      id: driver_id,
      cmd: "exec",
      payload: %({
        "__exec__": "perform_task",
        "perform_task": {
          "name": "steve"
        }
      })
    }.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    process.loaded[driver_id].queue.online = true

    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)

    # Check response was returned
    req_out = EngineDriver::Protocol::Request.from_json(String.new(raw_data[4, bytes_read - 4]))
    req_out.id.should eq(driver_id)
    req_out.cmd.should eq("result")
    req_out.payload.should eq(%("hello steve"))

    # execute a task response
    json = {
      id: driver_id,
      cmd: "exec",
      payload: %({
        "__exec__": "future_add",
        "future_add": {
          "a": 5,
          "b": 6
        }
      })
    }.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    process.loaded[driver_id].queue.online = true

    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)

    # Check response was returned
    req_out = EngineDriver::Protocol::Request.from_json(String.new(raw_data[4, bytes_read - 4]))
    req_out.id.should eq(driver_id)
    req_out.cmd.should eq("result")
    req_out.payload.should eq(%(11))

    # execute an erroring task response
    json = {
      id: driver_id,
      cmd: "exec",
      payload: %({
        "__exec__": "error_task",
        "error_task": {}
      })
    }.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    process.loaded[driver_id].queue.online = true

    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)

    # Check response was returned
    req_out = EngineDriver::Protocol::Request.from_json(String.new(raw_data[4, bytes_read - 4]))
    req_out.id.should eq(driver_id)
    req_out.cmd.should eq("result")
    req_out.payload.should eq("oops")
    req_out.error.should eq("ArgumentError")
    (req_out.backtrace.not_nil!.size > 0).should eq(true)

    # execute an erroring future response
    json = {
      id: driver_id,
      cmd: "exec",
      payload: %({
        "__exec__": "future_error",
        "future_error": {}
      })
    }.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    process.loaded[driver_id].queue.online = true

    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)

    # Check response was returned
    req_out = EngineDriver::Protocol::Request.from_json(String.new(raw_data[4, bytes_read - 4]))
    req_out.id.should eq(driver_id)
    req_out.cmd.should eq("result")
    req_out.payload.should eq("nooooo")
    req_out.error.should eq("ArgumentError")
    (req_out.backtrace.not_nil!.size > 0).should eq(true)

    # Check error was logged
    raw_data = Bytes.new(4096)
    bytes_read = logs.read(raw_data)
    String.new(raw_data[4, bytes_read - 4]).includes?("nooooo").should eq(true)

    # Ensure it terminates properly
    json = {
      id: "t",
      cmd: "terminate"
    }.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    process.loaded.size.should eq 1
    process.terminated.receive?
    process.loaded.size.should eq 0
  end
end
