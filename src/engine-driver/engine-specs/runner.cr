require "socket"
require "promise"
require "./mock_http"
require "./status_helper"
require "../protocol/request"

# TODO:: Add verbose mode that outputs way too much information about the comms

class EngineSpec
  SPEC_PORT = 0x45ae
  HTTP_PORT = SPEC_PORT + 1
  DRIVER_ID = "spec_runner"
  SYSTEM_ID = "spec_runner_system"

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
      spawn spec.__process_responses__

      # request a module instance be created by the driver
      json = {
        id: DRIVER_ID,
        cmd: "start",
        payload: {
          control_system: {
            id: SYSTEM_ID,
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
          # TODO:: use defaults exported from drivers -d switch
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
          id: DRIVER_ID,
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

    # Redis status
    @status = StatusHelper.new(DRIVER_ID)

    # Request Response tracking
    @request_sequence = 0_u64
    @requests = {} of UInt64 => Promise::DeferredPromise(JSON::Any?)
  end

  @comms : TCPSocket?
  getter :status

  def __start_http_server__
    @http_server.bind_tcp "127.0.0.1", HTTP_PORT
    @http_server.listen
  end

  def __start_server__
    while client = @server.accept?
      spawn @channel.send(client)
    end
  end

  def __process_responses__
    raw_data = Bytes.new(4096)
    tokenizer = ::Tokenizer.new do |io|
      begin
        io.read_bytes(Int32) + 4
      rescue
        0
      end
    end

    while !@io.closed?
      bytes_read = @io.read(raw_data)
      break if bytes_read == 0 # IO was closed

      tokenizer.extract(raw_data[0, bytes_read]).each do |message|
        string = nil
        begin
          string = String.new(message[4, message.bytesize - 4])
          request = EngineDriver::Protocol::Request.from_json(string)
          spawn do
            case request.cmd
            when "result"
              seq = request.seq
              promise = @requests.delete(seq)
              if promise
                if request.error
                  promise.reject(request.build_error)
                elsif payload = request.payload
                  promise.resolve(JSON.parse(payload))
                else
                  promise.resolve(nil)
                end
              end
            end
          end
        rescue error
          puts "error parsing request #{string.inspect}\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
        end
      end
    end
  rescue IO::Error
  rescue Errno
    # Input stream closed. This should only occur on termination
  end

  # A particular response might disconnect the socket
  # Then we want to wait for the reconnect to occur before continuing the spec
  def expect_reconnect(timeout = 5.seconds) : TCPSocket
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
    # Build the request
    function = function.to_s
    json = {
      id: DRIVER_ID,
      cmd: "exec",
      seq: @request_sequence,
      # This would typically be routing information
      # like the module requesting this exec or the HTTP request ID etc
      reply: "to_me",
      payload: {
        "__exec__" => function,
        function => args
      }.to_json
    }.to_json

    # Setup the tracking
    response = Promise::DeferredPromise(JSON::Any?).new
    @requests[@request_sequence] = response
    @request_sequence += 1_u64

    # Send the request
    @io.write_bytes json.bytesize
    @io.write json.to_slice
    @io.flush

    # The sleep here is for the lazy who don't want to explicitly track
    # the promise value and just want to check some state updated
    sleep 1.milliseconds
    response
  end
end
