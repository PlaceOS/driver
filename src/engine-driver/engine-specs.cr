require "socket"
require "./engine-specs/mock_http"

class EngineSpec
  SPEC_PORT = 0x45ae
  HTTP_PORT = SPEC_PORT + 1

  def self.mock_driver(driver_name : String, driver_exec = ENV["SPEC_RUN_DRIVER"])
    # Prepare driver IO
    stdin_reader, input = IO.pipe
    output, stderr_writer = IO.pipe
    io = IO::Stapled.new(output, input, true)
    wait_driver_close = Channel(Nil).new
    exited = false
    exit_code = -1

    begin
      # Load the driver (inherit STDOUT for logging)
      spawn do
        begin
          exit_code = Process.run(
            driver_exec,
            {"-p"},
            input: stdin_reader,
            output: STDOUT,
            error: stderr_writer
          ).exit_status
        ensure
          exited = true
          wait_driver_close.send(nil)
        end
      end

      Fiber.yield

      # Start comms
      spec = EngineSpec.new(driver_name, io)
      spawn spec.__start_server__
      spawn spec.__start_http_server__

      # request a module instance be created by the driver
      json = {
        id: "spec_runner",
        cmd: "start",
        payload: {
          control_system: {
            id: "spec_runner_system",
            name: "Spec Runner",
            email: "spec@acaprojects.com",
            capacity: 4,
            features: "many modules",
            bookable: true
          },
          ip: "127.0.0.1",
          uri: "http://127.0.0.1:#{HTTP_PORT}",
          udp: false,
          tls: false,
          port: SPEC_PORT,
          makebreak: false,
          role: 1,
          # TODO:: use defaults
          settings: {} of String => JSON::Any
        }.to_json
      }.to_json
      io.write_bytes json.bytesize
      io.write json.to_slice
      io.flush

      # Wait for a connection
      spec.expect_reconnect

      # Run the spec
      with spec yield

    ensure
      # Shutdown the driver
      if exited
        puts "WARNING: driver process exited with: #{exit_code}"
      else
        json = {
          id: "spec_runner",
          cmd: "terminate",
          payload: "{}"
        }.to_json
        io.write_bytes json.bytesize
        io.write json.to_slice
        io.flush

        spawn do
          sleep 1.seconds
          wait_driver_close.close
        end
        wait_driver_close.receive
      end
    end
  end

  def initialize(@driver_name : String, @io : IO::Stapled)
    # setup structures for handling HTTP request emulation
    @received_http = [] of MockHTTP
    @http_server = HTTP::Server.new do |context|
      request = MockHTTP.new(context)
      @received_http << request
      request.wait_for_data
    end

    # setup structures for handling IO
    @channel = Channel(TCPSocket).new
    @server = TCPServer.new("127.0.0.1", SPEC_PORT)
  end

  @comms : TCPSocket?

  def __start_http_server__
    @http_server.bind_tcp "127.0.0.1", HTTP_PORT
    @http_server.listen
  end

  def __start_server__
    while client = @server.accept?
      spawn @channel.send(client)
    end
  end

  def expect_reconnect(timeout = 20.seconds) : TCPSocket
    connection = nil

    # timeout
    spawn do
      sleep timeout
      @channel.close unless connection
    end

    @comms = connection = @channel.receive
    connection.not_nil!
  rescue error : Channel::ClosedError
    raise "timeout waiting for module to connect"
  end

  def exec(function, **args)
    function = function.to_s
    json = {
      id: "spec_runner",
      cmd: "exec",
      payload: {
        "__exec__" => function,
        function => args
      }.to_json
    }.to_json
    @io.write_bytes json.bytesize
    @io.write json.to_slice
    @io.flush
    self
  end
end
