require "spec"
require "promise"
require "../src/engine-driver"

class Helper
  # Creates the input / output IO required to test protocol functions
  def self.protocol
    input = IO::Stapled.new(*IO.pipe, true)
    output = IO::Stapled.new(*IO.pipe, true)
    proto = EngineDriver::Protocol.new(input, output)
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
        "makebreak": false,
        "role": 1,
        "settings": {"test": {"number": 123}}
      }),
    }.to_json
    input.write_bytes json.bytesize
    input.write json.to_slice

    sleep 0.01

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

  # A basic engine driver for testing
  class TestDriver < EngineDriver
    # This checks that any private methods are allowed
    private def test_private_ok(io)
      puts io
    end

    # Any method that requires a block is not included in the public API
    def add(a)
      a + yield
    end

    # Public API methods need to define argument types
    def add(a : Int32, b : Int32, *others)
      num = 0
      others.each { |o| num + o }
      a + b + num
    end

    # Public API will ignore splat arguments
    def splat_add(*splat, **dsplat)
      num = 0
      splat.each { |o| num + o }
      dsplat.values.each { |o| num + o }
      num
    end

    # using tasks and futures
    def perform_task(name : String)
      queue &.success("hello #{name}")
    end

    def error_task
      queue { raise ArgumentError.new("oops") }
    end

    def future_add(a : Int32, b : Int32)
      Promise.defer { sleep 0.01; a + b }
    end

    def future_error
      Promise.defer { raise ArgumentError.new("nooooo") }
    end

    # Other possibilities
    def raise_error
      raise ArgumentError.new("you fool!")
    end

    def not_json
      ArgumentError.new("you fool!")
    end

    def received(data, task)
      response = IO::Memory.new(data).to_s
      task.try &.success(response)
    end
  end

  macro new_driver(klass, module_id)
    %settings = Helper.settings
    %queue = Helper.queue
    %logger = EngineDriver::Logger.new({{module_id}})
    %driver = nil
    %transport = EngineDriver::TransportTCP.new(%queue, "localhost", 1234) do |data, task|
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
