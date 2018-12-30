require "spec"
require "../src/engine-driver"

class Helper
  def self.protocol
    inputr, inputw = IO.pipe
    input = IO::Stapled.new(inputr, inputw, true)
    outputr, outputw = IO.pipe
    output = IO::Stapled.new(outputr, outputw, true)
    proto = EngineDriver::Protocol.new(inputr, outputw)
    {proto, input, output}
  end

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

  def self.queue
    queue = EngineDriver::Queue.new
    spawn { queue.process! }
    queue
  end

  class TestDriver < EngineDriver
    def received(data, task)
      response = IO::Memory.new(data).to_s
      task.try &.success(response)
    end
  end
end
