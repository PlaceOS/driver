require "./helper"

# transports are required in a `macro finished` hook, so the class needs to be
# explicitly required here for the top level subclass below to resolve
require "../src/placeos-driver/transport/tcp"

# Exposes @socket so leak specs can assert on what `start_socket` left behind.
private class TestableTCP < PlaceOS::Driver::TransportTCP
  def socket_ref : IO?
    @socket
  end

  # Exposes the private consume_io for orphan-cleanup testing.
  def run_consume_io(socket)
    consume_io(socket)
  end
end

describe PlaceOS::Driver::TransportTCP do
  it "should work with a received function" do
    Helper.tcp_server

    queue = Helper.queue
    transport = PlaceOS::Driver::TransportTCP.new(queue, "localhost", 1234, ::PlaceOS::Driver::Settings.new("{}")) do |data, task|
      # This would usually call: driver.received(data, task)
      response = IO::Memory.new(data).to_s
      task.try &.success(response)
    end

    # driver = Helper::TestDriver.new(queue, transport)
    # transport.driver = driver
    transport.connect

    queue.online.should eq(true)

    task = queue.add { transport.send("test\n") }.response_required!
    task.get.payload.should eq(%("test"))

    # Close the connection
    transport.terminate
  end

  it "should work with a callback" do
    Helper.tcp_server

    queue = Helper.queue
    transport = PlaceOS::Driver::TransportTCP.new(queue, "localhost", 1234, ::PlaceOS::Driver::Settings.new("{}")) do |data, task|
      # This would usually call: driver.received(data, task)
      response = IO::Memory.new(data).to_s
      task.try &.success(response)
    end

    # driver = Helper::TestDriver.new(queue, transport)
    # transport.driver = driver
    transport.connect

    queue.online.should eq(true)

    in_callback = false
    task = queue.add do |req|
      transport.send("test\n", req) do |data|
        in_callback = true
        response = IO::Memory.new(data).to_s
        req.try &.success(response)
      end
    end
    task.response_required!
    task.get.payload.should eq(%("test"))
    in_callback.should eq(true)

    # Close the connection
    transport.terminate
  end

  # Regression: socket leak on start_socket failure.
  #
  # `start_socket` assigns the freshly-built TCPSocket to @socket BEFORE
  # `start_tls` runs. If start_tls raises (e.g. server isn't actually
  # speaking TLS), the rescue block doesn't close the TCPSocket — it stays
  # alive in @socket with an open file descriptor, kernel buffers, etc.
  # The next start_socket overwrites @socket with a fresh TCPSocket and
  # the previous one becomes an orphan, leaked until GC eventually
  # collects it.
  it "closes the underlying TCPSocket when TLS handshake fails during start_socket" do
    # Bare-TCP server that closes every connection immediately, forcing a
    # TLS handshake error on the client.
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    spawn do
      loop do
        client = server.accept?
        break unless client
        client.close rescue nil
      end
    end
    sleep 50.milliseconds

    queue = Helper.queue
    transport = TestableTCP.new(
      queue, "127.0.0.1", port,
      ::PlaceOS::Driver::Settings.new("{}"),
      true, # start_tls
      nil,  # uri
      true  # makebreak — skips SimpleRetry so we get a direct raise
) { |_data, _task| }

    expect_raises(Exception) { transport.connect }

    sock = transport.socket_ref
    sock.should_not be_nil
    # Without the fix: the TCPSocket is still open. With the fix: closed.
    sock.not_nil!.closed?.should be_true

    transport.terminate
    server.close
  end

  # Regression: orphan socket leak when consume_io's local socket has been
  # replaced.
  #
  # `consume_io`'s ensure block runs `disconnect unless socket != @socket`
  # — i.e. "if our socket is no longer the transport's current socket,
  # do nothing". That `do nothing` was the bug: the orphan stays alive
  # with an open file descriptor and kernel buffers. It happens whenever
  # concurrent connect() calls race past the `@socket.closed?` check
  # outside the mutex, or in makebreak mode when concurrent sends both
  # call connect().
  it "closes the orphan socket when consume_io's local socket is not the transport's current socket" do
    # Tiny server that accepts and closes immediately — gives us a socket
    # whose remote end is shut so consume_io exits via EOF.
    test_server = TCPServer.new("127.0.0.1", 0)
    port = test_server.local_address.port
    spawn do
      loop do
        client = test_server.accept?
        break unless client
        client.close rescue nil
      end
    end
    sleep 20.milliseconds

    orphan = TCPSocket.new("127.0.0.1", port)

    queue = Helper.queue
    # makebreak: true so consume_io's ensure skips the auto-reconnect
    # branch and the spec doesn't hang trying to reach port 1.
    transport = TestableTCP.new(
      queue, "127.0.0.1", 1,
      ::PlaceOS::Driver::Settings.new("{}"),
      false, # start_tls
      nil,   # uri
      true   # makebreak
) { |_data, _task| }

    # @socket is nil; orphan != @socket so consume_io must treat it as
    # orphaned and clean it up rather than leaving it open.
    transport.run_consume_io(orphan)

    orphan.closed?.should be_true

    transport.terminate
    test_server.close
  end

  it "should work with a pre-processor" do
    Helper.tcp_server

    queue = Helper.queue
    transport = PlaceOS::Driver::TransportTCP.new(queue, "localhost", 1234, ::PlaceOS::Driver::Settings.new("{}")) do |data, task|
      # This would usually call: driver.received(data, task)
      response = IO::Memory.new(data).to_s
      task.try &.success(response)
    end

    transport.pre_processor { |data| ("pre-" + String.new(data)).to_slice }

    # driver = Helper::TestDriver.new(queue, transport)
    # transport.driver = driver
    transport.connect

    queue.online.should eq(true)

    task = queue.add { transport.send("test\n") }.response_required!
    task.get.payload.should eq(%("pre-test"))

    transport.pre_processor = nil

    # Close the connection
    transport.terminate
  end
end
