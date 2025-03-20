require "spec"
require "promise"
require "./test_build"

PlaceOS::Driver.include_json_schema_in_interface = false

Spec.before_suite do
  ::Log.setup "*", :debug
end

class PlaceOS::Driver::ProcessManagerMock
  include PlaceOS::Driver::ProcessManagerInterface

  alias Request = PlaceOS::Driver::Protocol::Request

  class_getter callbacks : Hash(String, Proc(Request, Request?)) = {} of String => Request -> Request?

  def self.register(name : String, &callback : Request -> Request?)
    ProcessManagerMock.callbacks[name] = callback
  end

  def start(request : Protocol::Request, driver_model = nil) : Protocol::Request
    ProcessManagerMock.callbacks["start"]?.try(&.call(request))
    request
  end

  def stop(request : Protocol::Request) : Nil
  end

  def update(request : Protocol::Request) : Nil
  end

  def exec(request : Protocol::Request) : Protocol::Request
    request
  end

  def debug(request : Protocol::Request) : Nil
  end

  def ignore(request : Protocol::Request) : Nil
  end

  def info(request : Protocol::Request) : Protocol::Request
    request
  end

  def terminate : Nil
  end
end

class Helper
  # Creates the input / output IO required to test protocol functions
  def self.protocol
    manager = PlaceOS::Driver::ProcessManagerMock.new
    input = IO::Stapled.new(*IO.pipe, true)
    output = IO::Stapled.new(*IO.pipe, true)
    proto = PlaceOS::Driver::Protocol.new(input, output, 10.milliseconds, process_manager: manager)
    output.read_string(1)
    {proto, input, output}
  end

  def self.process
    input = IO::Stapled.new(*IO.pipe, true)
    output = IO::Stapled.new(*IO.pipe, true)
    logs = IO::Stapled.new(*IO.pipe, true)
    protocol = PlaceOS::Driver::Protocol.new(input, output, logger_io: logs)
    process = protocol.process_manager.as(PlaceOS::Driver::ProcessManager)
    process.loaded.size.should eq 0

    # Wait for ready signal
    output.read_string(1)

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

    sleep 10.milliseconds

    raw_data = Bytes.new(4096)
    bytes_read = output.read(raw_data)

    # Check start responded
    req_out = PlaceOS::Driver::Protocol::Request.from_json(String.new(raw_data[2, bytes_read - 4]))
    req_out.id.should eq(driver_id)
    req_out.cmd.start?.should be_true

    {process, input, output, logs, driver_id}
  end

  # Starts a simple TCP server for testing IO
  def self.tcp_server : Nil
    server = TCPServer.new("localhost", 1234)
    spawn(same_thread: true) do
      client = server.accept?.not_nil!
      server.close

      while message = client.gets
        client.write message.to_slice
      end
    end
  end

  # Returns a running queue
  def self.queue
    std_out = IO::Memory.new
    backend = ::Log::IOBackend.new(std_out)
    ::Log.builder.bind("driver.queue", level: ::Log::Severity::Debug, backend: backend)
    PlaceOS::Driver::Queue.new { }
  end

  macro new_driver(klass, module_id, protocol = nil)
    %settings = Helper.settings
    %queue = Helper.queue
    {% if protocol %}
      %logger = PlaceOS::Driver::Log.new({{module_id}}, protocol: {{protocol}})
    {% else %}
      %logger = PlaceOS::Driver::Log.new({{module_id}})
    {% end %}
    %driver = nil
    %transport = PlaceOS::Driver::TransportTCP.new(%queue, "localhost", 1234, ::PlaceOS::Driver::Settings.new("{}")) do |data, task|
      d = %driver.not_nil!
      if d.responds_to?(:received)
        d.received(data, task)
      else
        d.logger.warn { "no received function provided for #{d.class}" }
      end
    end
    %driver = {{klass}}.new {{module_id}}.to_s, %settings, %queue, %transport, %logger
  end

  macro settings
    std_out = IO::Memory.new
    backend = ::Log::IOBackend.new(std_out)
    logger = ::Log.new("driver.settings", backend, ::Log::Severity::Debug)
    settings = PlaceOS::Driver::Settings.new %({
      "integer": 1234,
      "string": "hello",
      "array": [12, 34, 54],
      "hash": {"hello": "world"},
      "float": 45
    })
  end
end
