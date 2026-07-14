require "./helper"

# transports are required in a `macro finished` hook, so the class needs to be
# explicitly required here for top level helpers below to resolve
require "../src/placeos-driver/transport/websocket"

# Exposes connection internals so specs can replay the interleaving of a
# disconnect fiber that resumed after a reconnect had already completed.
private class TestableWebsocket < PlaceOS::Driver::TransportWebsocket
  def websocket_ref
    @websocket
  end

  def generation_ref : UInt64
    @generation
  end

  # invokes the internal disconnect as if it had been initiated against an
  # older connection
  def stale_disconnect(generation : UInt64)
    disconnect(generation)
  end
end

# Simple websocket echo server that tracks the connections made to it so specs
# can drop connections server-side and observe reconnects.
private class WSTestServer
  getter port : Int32
  getter sockets = [] of HTTP::WebSocket
  getter connection_count : Int32 = 0

  def initialize
    ws_handler = HTTP::WebSocketHandler.new do |ws, _ctx|
      @connection_count += 1
      sockets << ws
      ws.on_message { |msg| ws.send(msg) }
    end
    @server = HTTP::Server.new([ws_handler])
    @port = @server.bind_unused_port("127.0.0.1").port
    server = @server
    spawn { server.listen }
    Fiber.yield
  end

  def close
    @server.close rescue nil
  end
end

private def wait_for(timeout = 5.seconds, &)
  deadline = Time.instant + timeout
  until yield
    raise "timed out waiting for condition" if Time.instant > deadline
    sleep 10.milliseconds
  end
end

describe PlaceOS::Driver::TransportWebsocket do
  it "should work with a received function" do
    server = WSTestServer.new
    queue = Helper.queue
    transport = PlaceOS::Driver::TransportWebsocket.new(
      queue, "ws://127.0.0.1:#{server.port}/",
      ::PlaceOS::Driver::Settings.new("{}"),
      -> { HTTP::Headers.new }
    ) do |data, task|
      task.try &.success(String.new(data))
    end

    transport.connect
    wait_for { queue.online }

    task = queue.add { transport.send("hello") }.response_required!
    task.get.payload.should eq(%("hello"))

    transport.terminate
    server.close
  end

  it "automatically reconnects when the device closes the connection" do
    server = WSTestServer.new
    queue = Helper.queue
    transport = PlaceOS::Driver::TransportWebsocket.new(
      queue, "ws://127.0.0.1:#{server.port}/",
      ::PlaceOS::Driver::Settings.new("{}"),
      -> { HTTP::Headers.new }
    ) { |_data, _task| }

    transport.connect
    wait_for { queue.online }
    server.connection_count.should eq(1)

    # device drops the connection
    server.sockets.first.close

    wait_for { server.connection_count == 2 && queue.online }

    transport.terminate
    server.close
  end

  # Regression: a stale `online = false` written by a delayed disconnect (one
  # that resumed from the yield in `websocket.close` after a reconnect had
  # already completed) was never corrected — `connect` early-returned on a
  # healthy socket without re-asserting the connected state, so the driver
  # reported disconnected forever while the websocket was alive and consuming.
  it "re-asserts the connected state when connect finds a healthy socket" do
    server = WSTestServer.new
    queue = Helper.queue
    transport = PlaceOS::Driver::TransportWebsocket.new(
      queue, "ws://127.0.0.1:#{server.port}/",
      ::PlaceOS::Driver::Settings.new("{}"),
      -> { HTTP::Headers.new }
    ) { |_data, _task| }

    transport.connect
    wait_for { queue.online }

    # simulate the stale offline write landing after the reconnect
    queue.online = false

    # any subsequent connect attempt sees the healthy socket and must
    # re-assert online rather than silently early-returning
    transport.connect
    queue.online.should be_true

    transport.terminate
    server.close
  end

  # Regression: `disconnect` yields at `websocket.close`. If the device
  # bounced the connection and a reconnect completed while the disconnect
  # fiber was suspended, the resumed fiber wrote `online = false` against the
  # new healthy connection and spawned a redundant reconnect — the production
  # false "disconnected" report.
  it "ignores a disconnect issued against a previous connection generation" do
    server = WSTestServer.new
    queue = Helper.queue
    transport = TestableWebsocket.new(
      queue, "ws://127.0.0.1:#{server.port}/",
      ::PlaceOS::Driver::Settings.new("{}"),
      -> { HTTP::Headers.new }
    ) { |_data, _task| }

    transport.connect
    wait_for { queue.online }
    stale_generation = transport.generation_ref

    # device bounces the connection, transport reconnects (new generation)
    server.sockets.first.close
    wait_for { server.connection_count == 2 && queue.online && transport.generation_ref > stale_generation }

    # the disconnect that was suspended in `websocket.close` while the
    # reconnect completed finally resumes
    transport.stale_disconnect(stale_generation)
    sleep 100.milliseconds

    # the new connection must remain online, open and un-churned
    queue.online.should be_true
    transport.websocket_ref.try(&.closed?).should be_false
    server.connection_count.should eq(2)

    transport.terminate
    server.close
  end

  it "still cycles the connection when disconnect is called for the current generation" do
    server = WSTestServer.new
    queue = Helper.queue
    transport = TestableWebsocket.new(
      queue, "ws://127.0.0.1:#{server.port}/",
      ::PlaceOS::Driver::Settings.new("{}"),
      -> { HTTP::Headers.new }
    ) { |_data, _task| }

    transport.connect
    wait_for { queue.online }

    # drivers can force a reconnect cycle via the public disconnect
    transport.disconnect
    wait_for { server.connection_count == 2 && queue.online }

    transport.terminate
    server.close
  end
end
