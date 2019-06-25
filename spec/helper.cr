require "spec"
require "promise"
require "./test_build"

class Helper
  # Creates the input / output IO required to test protocol functions
  def self.protocol
    input = IO::Stapled.new(*IO.pipe, true)
    output = IO::Stapled.new(*IO.pipe, true)
    proto = EngineDriver::Protocol.new(input, output, 10.milliseconds)
    {proto, input, output}
  end

  def self.process
    input = IO::Stapled.new(*IO.pipe, true)
    output = IO::Stapled.new(*IO.pipe, true)
    logs = IO::Stapled.new(*IO.pipe, true)
    process = EngineDriver::ProcessManager.new(logs, input, output)
    process.loaded.size.should eq 0

    driver_id = "mod_1234"

    # Start a driver
    json = {
      id:      driver_id,
      cmd:     "start",
      payload: %({
        "ip": "localhost",
        "port": 23,
        "udp": false,
        "tls": false,
        "makebreak": false,
        "role": 1,
        "settings": {"test": {"number": 123}}
      }),
    }.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    sleep 0.01

    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)

    # Check start responded
    req_out = EngineDriver::Protocol::Request.from_json(String.new(raw_data[4, bytes_read - 4]))
    req_out.id.should eq(driver_id)
    req_out.cmd.should eq("start")

    {process, input, output, logs, driver_id}
  end

  # Starts a simple TCP server for testing IO
  def self.tcp_server : Nil
    server = TCPServer.new("localhost", 1234)
    spawn do
      client = server.accept?.not_nil!
      server.close

      loop do
        message = client.gets
        break unless message
        client.write message.to_slice
      end
    end
  end

  # Returns a running queue
  def self.queue
    std_out = IO::Memory.new
    logger = ::Logger.new(std_out)
    EngineDriver::Queue.new(logger) { }
  end

  macro new_driver(klass, module_id)
    %settings = Helper.settings
    %queue = Helper.queue
    %logger = EngineDriver::Logger.new({{module_id}})
    %driver = nil
    %transport = EngineDriver::TransportTCP.new(%queue, "localhost", 1234, ::EngineDriver::Settings.new("{}")) do |data, task|
      d = %driver.not_nil!
      if d.responds_to?(:received)
        d.received(data, task)
      else
        d.logger.warn "no received function provided for #{d.class}"
      end
    end
    %driver = {{klass}}.new {{module_id}}.to_s, %settings, %queue, %transport, %logger
  end

  macro settings
    std_out = IO::Memory.new
    logger = ::Logger.new(std_out)
    settings = EngineDriver::Settings.new %({
      "integer": 1234,
      "string": "hello",
      "array": [12, 34, 54],
      "hash": {"hello": "world"}
    })
  end
end
