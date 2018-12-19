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
end
