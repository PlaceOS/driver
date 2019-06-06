require "socket"
require "tokenizer"
require "./mock_http"
require "./responder"
require "./status_helper"
require "spec/dsl"
require "spec/methods"
require "spec/expectations"
require "../protocol/request"

# TODO:: Add verbose mode that outputs way too much information about the comms
STDOUT.sync = true
STDERR.sync = true

# An engine driver has 4 typical points of IO contact
# 1. Engine driver protocol (engine-core's point of contact)
# 2. The modules transport layer (module to device comms)
# 3. An optional HTTP client
# 4. Redis for state storage and subscriptions
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
      # -p is for protocol / process mode - expecting engine core
      spawn do
        begin
          puts "Launching driver: #{driver_exec}"
          exit_code = Process.run(
            driver_exec,
            {"-p"},
            input: stdin_reader,
            output: STDOUT,
            error: stderr_writer
          ).exit_status
          puts "Driver terminated with: #{exit_code}"
        ensure
          exited = true
          wait_driver_close.send(nil)
        end
      end

      Fiber.yield

      # Start comms
      puts "... starting driver IO services"
      spec = EngineSpec.new(driver_name, io)
      spawn spec.__start_server__
      spawn spec.__start_http_server__
      spawn spec.__process_responses__

      puts "... requesting default settings"
      defaults_io = IO::Memory.new
      Process.run(
        driver_exec, {"-d"},
        input: Process::Redirect::Close,
        output: defaults_io,
        error: Process::Redirect::Close
      )
      defaults = JSON.parse(JSON.parse(defaults_io.to_s.strip)["default_settings"].as_s)
      puts "... got default settings: #{defaults.inspect}"

      # request a module instance be created by the driver
      puts "... starting module"
      json = {
        id:      DRIVER_ID,
        cmd:     "start",
        payload: {
          control_system: {
            id:       SYSTEM_ID,
            name:     "Spec Runner",
            email:    "spec@acaprojects.com",
            capacity: 4,
            features: "many modules",
            bookable: true,
          },
          ip:        "127.0.0.1",
          uri:       "http://127.0.0.1:#{HTTP_PORT}",
          udp:       false,
          tls:       false,
          port:      SPEC_PORT,
          makebreak: false,
          role:      1,
          # use defaults as defined in the driver
          settings: defaults,
        }.to_json,
      }.to_json
      io.write_bytes json.bytesize
      io.write json.to_slice
      io.flush

      # Wait for a connection
      puts "... waiting for module"
      spec.expect_reconnect
      puts "... module connected"

      # request that debugging be enabled
      puts "... enabling debugging output"
      json = {
        id:  DRIVER_ID,
        cmd: "debug",
      }.to_json
      io.write_bytes json.bytesize
      io.write json.to_slice
      io.flush

      # Run the spec
      puts "... starting spec"
      begin
        with spec yield
      rescue e
        e.inspect_with_backtrace(STDOUT)
      end
      puts "... spec complete"
    ensure
      # Shutdown the driver
      if exited
        puts "WARNING: driver process exited with: #{exit_code}"
      else
        puts "... terminating driver gracefully"
        json = {
          id:      DRIVER_ID,
          cmd:     "terminate",
          payload: "{}",
        }.to_json
        io.write_bytes json.bytesize
        io.write json.to_slice
        io.flush

        spawn do
          sleep 1.seconds
          puts "WARNING: driver process failed to terminate gracefully"
          wait_driver_close.close
        end
        wait_driver_close.receive
      end
    end
  end

  def initialize(@driver_name : String, @io : IO::Stapled)
    # setup structures for handling HTTP request emulation
    @received_http = [] of MockHTTP
    @expected_http = [] of Channel(MockHTTP)
    @http_server = HTTP::Server.new do |context|
      request = MockHTTP.new(context)
      if @expected_http.empty?
        @received_http << request
      else
        @expected_http.shift.send(request)
      end
      request.wait_for_data
    end

    # setup structures for handling IO
    @new_connection = Channel(TCPSocket).new
    @server = TCPServer.new("127.0.0.1", SPEC_PORT)

    # Redis status
    @status = StatusHelper.new(DRIVER_ID)

    # Request Response tracking
    @request_sequence = 0_u64
    @requests = {} of UInt64 => Channel(EngineDriver::Protocol::Request)

    # Transmit tracking
    @transmissions = [] of Bytes
    @expected_transmissions = [] of Channel(Bytes)
  end

  @comms : TCPSocket?
  getter :status

  def __start_http_server__
    @http_server.bind_tcp "127.0.0.1", HTTP_PORT
    @http_server.listen
  end

  def __start_server__
    while client = @server.accept?
      spawn @new_connection.send(client)
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
              responder = @requests.delete(seq)
              responder.send(request) if responder
            when "debug"
              debug = JSON.parse(request.payload.not_nil!)
              severity = debug[0].as_i
              # Warnings and above will already be written to STDOUT
              if severity < 2
                text = debug[1].as_s
                level = severity == 0 ? "DEBUG" : "INFO"
                puts "level=#{level} message=#{text}"
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

  def __process_transmissions__(connection : TCPSocket)
    # 128kb buffer should be enough for anyone
    raw_data = Bytes.new(1024 * 128)

    while !connection.closed?
      bytes_read = connection.read(raw_data)
      break if bytes_read == 0 # IO was closed

      data = raw_data[0, bytes_read]
      if @expected_transmissions.empty?
        @transmissions << data
      else
        @expected_transmissions.shift.send(data)
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
      @new_connection.close unless connection
    end

    @comms = connection = socket = @new_connection.receive
    spawn { __process_transmissions__(socket) }
    socket
  rescue error : Channel::ClosedError
    raise "timeout waiting for module to connect"
  end

  def exec(function, **args)
    # We want to clear any previous transmissions
    @transmissions.clear

    puts "-> spec calling: #{function} #{args}"

    # Build the request
    function = function.to_s.gsub("?", "_question_mark_").gsub("!", "_exclamation_mark_")
    json = {
      id:  DRIVER_ID,
      cmd: "exec",
      seq: @request_sequence,
      # This would typically be routing information
      # like the module requesting this exec or the HTTP request ID etc
      reply:   "to_me",
      payload: {
        "__exec__" => function,
        function   => args,
      }.to_json,
    }.to_json

    # Setup the tracking
    response = Responder.new
    @requests[@request_sequence] = response.channel
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

  def should_send(data, timeout = 500.milliseconds)
    sent = Bytes.new(0)

    if @transmissions.empty?
      channel = Channel(Bytes).new(1)

      # Timeout
      spawn do
        sleep timeout
        if sent.empty?
          channel.close
          puts "-> timeout waiting for expected data"
        end
      end

      @expected_transmissions << channel
      begin
        sent = channel.receive
      ensure
        @expected_transmissions.delete(channel)
      end
    else
      sent = @transmissions.shift
    end

    # coerce expected send into a byte array
    data = if data.responds_to? :to_io
             io = IO::Memory.new
             io.write_bytes data
             io.to_slice
           elsif data.responds_to? :to_slice
             data.to_slice
           else
             data
           end

    # Check if it matches
    if sent.size > data.size
      sent[0...data.size].should eq(data)
      if @expected_transmissions.empty?
        @transmissions << data
      else
        @expected_transmissions.shift.send(sent[data.size..-1])
      end
    else
      sent.should eq(data)
    end

    self
  end

  def transmit(data)
    puts "-> transmitting: #{data.inspect}"

    data = if data.responds_to? :to_io
             io = IO::Memory.new
             io.write_bytes data
             io.to_slice
           elsif data.responds_to? :to_slice
             data.to_slice
           else
             data
           end
    @comms.not_nil!.write data
    sleep 10.milliseconds
    nil
  end

  def responds(data)
    transmit(data)
  end

  def expect_http_request(timeout = 500.milliseconds)
    mock_http = if @received_http.empty?
                  temp_http = nil
                  channel = Channel(MockHTTP).new(1)

                  # Timeout
                  spawn do
                    sleep timeout
                    if temp_http.nil?
                      puts "-> timeout waiting for expected HTTP request"
                      channel.close
                    end
                  end

                  @expected_http << channel
                  begin
                    temp_http = channel.receive
                  ensure
                    @expected_http.delete(channel)
                  end
                else
                  @received_http.shift
                end

    puts "-> expected HTTP request received"

    # Make a copy of the body for debugging later
    io = mock_http.context.request.body
    request_body = begin
      io ? String.new(io.peek || Bytes.new(0)) : ""
    rescue
      io ? io.peek.inspect : ""
    end

    # Process the request
    begin
      yield mock_http.context.request, mock_http.context.response
    rescue e
      puts "-> ------"
      puts "   unhandled error processing request:\n#{mock_http.context.request.inspect}"
      puts "   request body:\n#{request_body}"
      puts "-> ------"
      raise e
    end
    mock_http.complete_request
    self
  end
end
