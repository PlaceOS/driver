require "http/server"

class EngineSpec; end

class EngineSpec::MockHTTP
  def initialize(@context : HTTP::Server::Context)
    @channel = Channel(Nil).new
  end

  getter context

  def wait_for_data
    @channel.receive
  end

  def complete_request
    @channel.send(nil)
  end
end
