require "spec"
require "../src/engine-driver"

class Helper
  # Creates the input / output IO required to test protocol functions
  def self.protocol
    inputr, inputw = IO.pipe
    input = IO::Stapled.new(inputr, inputw, true)
    outputr, outputw = IO.pipe
    output = IO::Stapled.new(outputr, outputw, true)
    proto = EngineDriver::Protocol.new(inputr, outputw)
    {proto, input, output}
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
    queue = EngineDriver::Queue.new
    spawn { queue.process! }
    queue
  end

  # A basic engine driver for testing
  class TestDriver < EngineDriver
    # This checks that any private methods are allowed
    private def test_private_ok(io)
      puts io
    end

    def received(data, task)
      response = IO::Memory.new(data).to_s
      task.try &.success(response)
    end
  end

  macro new_driver(klass, module_id)
    %settings = Helper.settings
    %queue = Helper.queue
    %logger = EngineDriver::Logger.new({{module_id}}, EngineDriver::Protocol.instance)
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

  def self.settings
    EngineDriver::Settings.new %({
      "integer": 1234,
      "string": "hello",
      "array": [12, 34, 54],
      "hash": {"hello": "world"}
    })
  end
end
