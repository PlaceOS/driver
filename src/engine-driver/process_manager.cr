require "json"

class EngineDriver::ProcessManager
  def initialize(@input = STDIN, output = STDERR)
    @subscriptions = Subscriptions.new
    @protocol = EngineDriver::Protocol.instance(@input, output)
    @logger = @subscriptions.logger

    @loaded = [] of DriverManager

    @protocol.register :start { |request| start(request) }
    @protocol.register :stop { |request| stop(request) }
    @protocol.register :update { |request| update(request) }
    @protocol.register :exec { |request| exec(request) }
    @protocol.register :debug { |request| debug(request) }
    @protocol.register :ignore { |request| ignore(request) }
    @protocol.register :terminate { terminate }
  end

  @input : IO
  @logger : ::Logger
  getter :logger

  def start(request : Protocol::Request)
    module_id = request.id
    model = EngineDriver::DriverModel.from_json(request.payload.not_nil!)
    driver = DriverManager.new module_id, model
    driver
  end

  def stop(request : Protocol::Request)
  end

  def update(request : Protocol::Request)
  end

  def exec(request : Protocol::Request)
  end

  def debug(request : Protocol::Request)
  end

  def ignore(request : Protocol::Request)
  end

  def terminate
    @input.close
    @subscriptions.terminate
    @loaded.each &.terminate
    @loaded.clear
    nil
  end
end
