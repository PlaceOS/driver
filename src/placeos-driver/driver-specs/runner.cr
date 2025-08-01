require "log"
require "yaml"
require "debug"
require "socket"
require "promise"
require "colorize"
require "tokenizer"
require "./mock_http"
require "./responder"
require "./mock_driver"
require "./status_helper"
require "spec/dsl"
require "spec/methods"
require "spec/expectations"
require "../protocol/request"
require "../storage"

# TODO:: Add verbose mode that outputs way too much information about the comms
STDOUT.sync = true
STDERR.sync = true

# Enable explicit debugging
Debug.enabled = true

# A place driver has 4 typical points of IO contact
# 1. Place driver protocol (placeos-core's point of contact)
# 2. The modules transport layer (module to device comms)
# 3. An optional HTTP client
# 4. Redis for state storage and subscriptions
class DriverSpecs
  DRIVER_ID = "spec_runner"
  SYSTEM_ID = "spec_runner_system"

  getter example_count : Int32 = 0
  getter errors : Array(Tuple(Exception, String, String, Int32)) = [] of Tuple(Exception, String, String, Int32)

  def it(description : String, file = __FILE__, line = __LINE__, **args, &)
    @example_count += 1
    with self yield
  rescue error
    @errors << {error, description, file, line}
  end

  def self.mock_driver(driver_name : String, driver_exec = ENV["SPEC_RUN_DRIVER"], &)
    # Prepare driver IO
    unix_socket = File.tempname("pos", ".driver")
    unix_server = UNIXServer.new(unix_socket)
    wait_driver_open = Channel(UNIXSocket).new

    # no need to keep the server open once the process has checked in
    spawn do
      client = unix_server.accept?
      wait_driver_open.send client.as(UNIXSocket)
      unix_server.close
    end

    wait_driver_close = Channel(Nil).new
    exited = false
    exit_code = -1

    # Configure logging
    ::Log.builder.bind "*", :debug, ::Log::IOBackend.new

    # Ensure the system lookup is not in place
    storage = PlaceOS::Driver::RedisStorage.new(SYSTEM_ID, "system")
    storage.clear

    fetch_pid = Promise.new(Int64)

    # Load the driver (inherit STDOUT for logging)
    # -p is for protocol / process mode - expecting placeos core
    spawn(same_thread: true) do
      begin
        puts "Launching driver: #{driver_exec.colorize(:green)}"
        Process.run(
          driver_exec,
          {"-p", "-s", unix_socket},
          {"DEBUG" => "1", "CURRENT_DRIVER_PATH" => driver_exec},
          output: STDOUT,
          error: STDOUT
        ) do |process|
          fetch_pid.resolve process.pid
        end

        exit_code = $?.exit_code
        puts "Driver terminated with: #{exit_code}"
      ensure
        exited = true
        wait_driver_open.close
        wait_driver_close.send(nil)
      end
    end

    pid = fetch_pid.get

    select
    when conn = wait_driver_open.receive
    when timeout(5.seconds)
      raise "timeout waiting for driver comms to be established"
    end
    io = conn.not_nil!

    begin
      # Wait for the driver to be ready
      io.read_string(1)
      io.sync = false

      puts "... requesting default settings"
      defaults_io = IO::Memory.new
      Process.run(
        driver_exec, {"-d"},
        input: Process::Redirect::Close,
        output: defaults_io,
        error: Process::Redirect::Close
      )

      defaults_raw = defaults_io.to_s.strip
      defaults = begin
        JSON.parse(defaults_raw)
      rescue error
        puts "error parsing driver defaults:\n#{defaults_raw.inspect}"
        raise error
      end
      default_settings = JSON.parse(defaults["default_settings"].as_s)
      puts "... got default settings: #{default_settings.inspect.colorize(:green)}"

      # Check for makebreak
      makebreak = !!(defaults["makebreak"]?.try &.as_bool)

      # Start comms
      puts "... starting driver IO services"
      spec = DriverSpecs.new(driver_name, io, makebreak, default_settings)
      spawn(same_thread: true) { spec.__start_server__ }
      spawn(same_thread: true) { spec.__start_http_server__ }
      spawn(same_thread: true) { spec.__process_responses__ }
      Fiber.yield

      tcp_port, http_port = spec.__get_ports__

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
            features: ["many", "modules"],
            bookable: true,
            zones:    ["zone-1234", "zone-level", "zone-building", "zone-org"],
            timezone: "Australia/Sydney",
          },
          ip:        "127.0.0.1",
          uri:       "http://127.0.0.1:#{http_port}",
          udp:       false,
          tls:       false,
          port:      tcp_port,
          makebreak: makebreak,
          role:      1,
          # use defaults as defined in the driver
          settings: default_settings,
        }.to_json,
      }.to_json
      io.write_bytes json.bytesize
      io.write json.to_slice
      io.flush

      if makebreak
        puts "... starting in makebreak! mode"
        # Give the module some time to startup
        sleep 200.milliseconds
      else
        # Wait for a connection
        puts "... waiting for module"
        spec.expect_reconnect
        puts "... module connected"
      end

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
        # Stopping the module
        puts "... stopping the module"
        json = {
          id:  DRIVER_ID,
          cmd: "stop",
        }.to_json
        io.write_bytes json.bytesize
        io.write json.to_slice
        io.flush

        # give it a moment to shutdown
        sleep 1.second

        if spec.errors.empty?
          puts "    #{spec.example_count} examples, 0 errors" if spec.example_count > 0
          puts "... spec passed".colorize(:green)
        else
          puts "\nFailures:"
          spec.errors.each_with_index do |error, index|
            puts "\n  #{index + 1}) #{error[1]}"
            puts error[0].inspect_with_backtrace.colorize(:red)
            puts "\n  # #{error[2]}:#{error[3]}".colorize(:blue)
          end
          puts "\n    #{spec.example_count} examples, #{spec.errors.size} errors"
          puts "Failed examples:"
          spec.errors.each do |error|
            print "  - #{error[2]}:#{error[3]}".colorize(:red)
            puts " # #{error[1]}".colorize(:blue)
          end
          puts "\n... spec failed".colorize(:red)
        end
      rescue e
        puts "level=ERROR : unhandled exception in spec".colorize(:red)
        e.inspect_with_backtrace(STDOUT)
        puts "... spec failed".colorize(:red)
      end
    ensure
      # Shutdown the driver
      if exited
        puts "level=ERROR : driver process exited with: #{exit_code}".colorize(:red)
        puts "... please ensure `redis-server` is running locally" if exit_code == 256
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

        select
        when wait_driver_close.receive?
        when timeout(5.seconds)
          puts "level=ERROR : driver process failed to terminate gracefully".colorize(:red)
          Process.run("kill", {"-9", pid.to_s})
          wait_driver_close.close
        end
      end
    end
  end

  # :nodoc:
  def initialize(@driver_name : String, @io : UNIXSocket, @makebreak : Bool, @current_settings : JSON::Any)
    # setup structures for handling HTTP request emulation
    @mock_drivers = {} of String => MockDriver
    @write_mutex = Mutex.new
    @event_mutex = Mutex.new

    @received_http = [] of MockHTTP
    @expected_http = [] of Channel(MockHTTP)
    @http_server = HTTP::Server.new do |context|
      request = MockHTTP.new(context)
      @event_mutex.synchronize do
        if @expected_http.empty?
          @received_http << request
        else
          @expected_http.shift.send(request)
        end
      end
      request.wait_for_data
    end

    # setup structures for handling IO
    @new_connection = Channel(TCPSocket).new
    @server = TCPServer.new("127.0.0.1", 0)
    @http_port = @http_server.bind_unused_port.port

    # Redis status
    @status = StatusHelper.new(DRIVER_ID)

    # Request Response tracking
    @request_sequence = 0_u64
    @requests = {} of UInt64 => Channel(PlaceOS::Driver::Protocol::Request)

    # Transmit tracking
    @transmissions = [] of Bytes
    @expected_transmissions = [] of Channel(Bytes)
  end

  @http_port : Int32
  @comms : TCPSocket?

  # provides access to the drivers status state.
  #
  # `status[:volume].should eq(50)`
  getter :status

  # :nodoc:
  def __start_http_server__
    @http_server.listen
  end

  # :nodoc:
  def __start_server__
    while client = @server.accept?
      spawn(same_thread: true) { @new_connection.send(client.as(TCPSocket)) }
    end
  end

  # :nodoc:
  def __get_ports__
    {@server.local_address.port, @http_port}
  end

  # :nodoc:
  def __process_responses__
    raw_data = Bytes.new(4096)
    tokenizer = Tokenizer.new(Bytes[0x00, 0x03])

    while !@io.closed?
      bytes_read = @io.read(raw_data)
      break if bytes_read == 0 # IO was closed

      tokenizer.extract(raw_data[0, bytes_read]).each do |message|
        string = nil
        begin
          string = String.new(message[0..-3])
          _, _, string = string.rpartition("\x00\x02")
          request = PlaceOS::Driver::Protocol::Request.from_json(string)
          spawn(same_thread: true) do
            case request.cmd
            when .result?
              seq = request.seq
              responder = @requests.delete(seq)
              responder.send(request) if responder
            when .debug?
              debug = JSON.parse(request.payload.not_nil!)
              severity = debug[0].as_i
              # Warnings and above will already be written to STDOUT
              if severity < 3
                text = debug[1].as_s
                level = Log::Severity.from_value(severity).to_s.upcase
                puts "level=#{level} message=#{text}"
              end
            when .exec?
              module_id = request.id
              exec_payload = request.payload.not_nil!
              mod = @mock_drivers[module_id]

              # Return the result
              begin
                request.payload = mod.__executor(exec_payload).execute(mod)
                request.cmd = :result
              rescue error
                request.set_error(error)
              end
              json = request.to_json

              # Send the result
              @write_mutex.synchronize do
                @io.write_bytes json.bytesize
                @io.write json.to_slice
                @io.flush
              end
            when .setting?
              setting_name, setting_value = Tuple(String, YAML::Any).from_yaml(request.payload.not_nil!)
              curr_settings = @current_settings.as_h
              curr_settings[setting_name] = JSON.parse(setting_value.to_json)
              settings(curr_settings)
            else
              puts "ignoring command #{request.cmd} in driver-runner server #{request.error}"
            end
          end
        rescue error
          puts "error parsing request #{string.inspect}\n#{error.inspect_with_backtrace}"
        end
      end
    end
  rescue IO::Error
    # Input stream closed. This should only occur on termination
  end

  # :nodoc:
  def __process_transmissions__(connection : TCPSocket)
    # 1MB buffer should be enough for anyone
    raw_data = Bytes.new(1024 * 1024)

    while !connection.closed?
      bytes_read = connection.read(raw_data)
      break if bytes_read == 0 # IO was closed

      data = raw_data[0, bytes_read].dup
      @event_mutex.synchronize do
        if @expected_transmissions.empty?
          @transmissions << data
        else
          @expected_transmissions.shift.send(data)
        end
      end
    end
  rescue IO::Error
    # Input stream closed. This should only occur on termination
  end

  # A particular response might disconnect the socket
  # Then we want to wait for the reconnect to occur before continuing the spec
  def expect_reconnect(timeout = 5.seconds) : TCPSocket
    connection = nil

    # timeout
    spawn(same_thread: true) do
      sleep timeout
      @new_connection.close unless connection
    end

    @comms = connection = socket = @new_connection.receive
    spawn(same_thread: true) { __process_transmissions__(socket) }
    socket
  rescue error : Channel::ClosedError
    raise "timeout waiting for module to connect"
  end

  # executes a function on the driver being tested and returns response promise
  #
  # i.e. `response = exec(:method_on_driver, arg1, arg2)`
  #
  # then to process the response `response.get.should eq "method response"`
  def exec(function, *args, user_id = nil)
    resp = __exec__(function, args, user_id)
    sleep 2.milliseconds
    resp
  end

  # :ditto:
  def exec(function, user_id = nil, **args)
    resp = __exec__(function, args, user_id)
    sleep 2.milliseconds
    resp
  end

  # :ditto:
  def exec(function, *args, user_id = nil, &)
    resp = __exec__(function, args, user_id)
    yield resp
    resp
  end

  # :ditto:
  def exec(function, user_id = nil, **args, &)
    resp = __exec__(function, args, user_id)
    yield resp
    resp
  end

  # :nodoc:
  def __exec__(function, args, user_id)
    puts "-> spec calling: #{function.colorize(:green)} #{args.to_s.colorize(:green)} (user: #{user_id})"

    # Build the request
    json = {
      id:  DRIVER_ID,
      cmd: "exec",
      seq: @request_sequence,
      # This would typically be routing information
      # like the module requesting this exec or the HTTP request ID etc
      reply:   "to_me",
      user_id: user_id,
      payload: {
        "__exec__" => function,
        function   => args,
      }.to_json,
    }.to_json

    # Setup the tracking
    response = Responder.new
    @requests[@request_sequence] = response.channel
    @request_sequence += 1_u64

    # We want to clear any previous transmissions
    @event_mutex.synchronize { @transmissions.clear }

    # Send the request
    @write_mutex.synchronize do
      @io.write_bytes json.bytesize
      @io.write json.to_slice
      @io.flush
    end

    response
  end

  # obtain some data you were expecting to receive from the driver. Typically triggered by an exec you've made.
  #
  # `expect_send.should eq "some data"`
  def expect_send(timeout = 500.milliseconds) : Bytes
    channel = nil

    @event_mutex.synchronize do
      if @transmissions.empty?
        channel = Channel(Bytes).new(1)
        @expected_transmissions << channel
      end
    end

    if channel
      begin
        select
        when received = channel.receive
          return received
        when timeout(timeout)
          puts "level=ERROR : timeout waiting for data".colorize(:red)
          raise "timeout waiting for data"
        end
      ensure
        @event_mutex.synchronize { @expected_transmissions.delete(channel) }
      end
    else
      @event_mutex.synchronize { @transmissions.shift }
    end
  end

  # expects the data provided to be sent
  #
  # `should_send "some data"`
  def should_send(data, timeout = 500.milliseconds)
    sent = Bytes.new(0)
    channel = nil

    @event_mutex.synchronize do
      if @transmissions.empty?
        channel = Channel(Bytes).new(1)
        @expected_transmissions << channel.not_nil!
      end
    end

    if channel
      # Timeout
      tdata = data
      spawn(same_thread: true) do
        sleep timeout
        if sent.empty?
          channel.not_nil!.close
          puts "level=ERROR : timeout waiting for expected data\n-> expecting: #{tdata.inspect}".colorize(:red)
        end
      end

      begin
        sent = channel.not_nil!.receive
      ensure
        @event_mutex.synchronize { @expected_transmissions.delete(channel) }
      end
    else
      sent = @event_mutex.synchronize { @transmissions.shift }
    end

    # coerce expected send into a byte array
    raw_data = if data.responds_to? :to_io
                 io = IO::Memory.new
                 io.write_bytes data
                 io.to_slice
               elsif data.responds_to? :to_slice
                 data.to_slice
               else
                 data
               end

    # Check if it matches
    begin
      if sent.size > raw_data.size
        sent[0...raw_data.size].should eq(raw_data)
        @event_mutex.synchronize do
          if @expected_transmissions.empty?
            @transmissions << raw_data
          else
            @expected_transmissions.shift.send(sent[raw_data.size..-1])
          end
        end
      else
        sent.should eq(raw_data)
      end
    rescue e : Spec::AssertionFailed
      # Print out some human friendly results
      begin
        puts "level=ERROR : expected vs received".colorize(:red)
        puts "... #{String.new(raw_data)}"
        puts "... #{String.new(sent)}"
      rescue
        # We shouldn't worry if the data isn't UTF8 compatible
        # The error will display the byte data
      end
      raise e
    end

    self
  end

  # transmits some data to the driver, typically a response to something the driver has sent
  #
  # `transmit "\nsome response"`
  def transmit(data, pause = 100.milliseconds)
    comms = @comms
    if comms && !comms.closed?
    else
      puts "level=WARN : Attempting to transmit: #{data.inspect}".colorize(:orange)
      raise "module is currently disconnected, cannot transmit data"
    end
    return unless comms

    puts "-> transmitting: #{data.inspect.colorize(:green)}"

    data = if data.responds_to? :to_io
             io = IO::Memory.new
             io.write_bytes data
             io.to_slice
           elsif data.responds_to? :to_slice
             data.to_slice
           else
             data
           end
    comms.write data
    comms.flush
    sleep pause
    self
  end

  # :ditto:
  def responds(data)
    transmit(data)
  end

  # provides a method for accepting and responding to HTTP requests being made by the driver
  #
  # for an example of how this works see [an existing driver](https://github.com/PlaceOS/drivers/blob/master/drivers/message_media/sms_spec.cr#L10-L25)
  def expect_http_request(timeout = 1.seconds, &)
    channel = nil

    @event_mutex.synchronize do
      if @received_http.empty?
        channel = Channel(MockHTTP).new(1)
        @expected_http << channel
      end
    end

    mock_http = if channel
                  select
                  when temp_http = channel.receive
                    temp_http
                  when timeout(timeout)
                    puts "level=ERROR : timeout waiting for expected HTTP request".colorize(:red)
                    @event_mutex.synchronize { @expected_http.delete(channel) }
                    raise "timeout waiting for expected HTTP request"
                  end
                else
                  @event_mutex.synchronize { @received_http.shift }
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
    sleep 10.milliseconds
    self
  end

  # publish an event for the driver to process
  def publish(channel, message)
    message = message.to_s
    PlaceOS::Driver::RedisStorage.with_redis &.publish("placeos/#{channel}", message)
    puts "-> spec published: #{channel} -> #{message}"
    message
  end

  # =============
  # Logic Helpers
  # =============

  # provides a new system definition for testing Logic Modules
  #
  # expects {ModuleName: {Klass, Klass}}
  #
  # see [an example](https://github.com/PlaceOS/drivers/blob/master/drivers/place/bookings_spec.cr#L5-L8) of it in use
  def system(details)
    system_index = PlaceOS::Driver::RedisStorage.new(SYSTEM_ID, "system")
    system_index.clear

    @mock_drivers.clear

    details.each do |key, entries|
      index = 1

      entries.each do |driver|
        system_key = "#{key}/#{index}"
        module_id = "mod-#{system_key}"

        # Create the mock driver
        @mock_drivers[module_id] = driver.new(module_id)

        # Index the driver
        system_index[system_key] = module_id
        index += 1
      end
    end

    # Signal that the system has changed for any subscriptions
    PlaceOS::Driver::RedisStorage.with_redis do |redis|
      redis.publish "lookup-change", SYSTEM_ID
    end
    settings(@current_settings)
    self
  end

  # Grab a Mock driver instance that has been defined by updating the system
  #
  # For example a system may look like: `{Display: {MockDisplay, MockDisplay}}`
  #
  # We can obtain mock display 2 by calling `mock_display = system(:Display_2)`
  #
  # Then we can check status on it `mock_display[:power]?.should eq true`
  def system(module_id : String | Symbol)
    mod_name, match, index = module_id.to_s.rpartition('_')
    mod_name, index = if match.empty?
                        {module_id, 1}
                      else
                        {mod_name, index.to_i}
                      end
    @mock_drivers["mod-#{mod_name}/#{index}"]
  end

  # allows you to provide alternative settings to the driver being tested.
  #
  # by default the drivers `default_settings` are used
  def settings(new_settings)
    @current_settings = JSON.parse(new_settings.to_json)
    tcp_port, http_port = __get_ports__

    json = {
      id:      DRIVER_ID,
      cmd:     "update",
      payload: {
        control_system: {
          id:       SYSTEM_ID,
          name:     "Spec Runner",
          email:    "spec@acaprojects.com",
          capacity: 4,
          features: ["many", "modules"],
          bookable: true,
          zones:    ["zone-1234", "zone-level", "zone-building", "zone-org"],
          timezone: "Australia/Sydney",
        },
        ip:        "127.0.0.1",
        uri:       "http://127.0.0.1:#{http_port}",
        udp:       false,
        tls:       false,
        port:      tcp_port,
        makebreak: @makebreak,
        role:      1,
        # use defaults as defined in the driver
        settings: @current_settings,
      }.to_json,
    }.to_json

    puts "... updating settings: #{new_settings.inspect.colorize(:green)}"

    @write_mutex.synchronize do
      @io.write_bytes json.bytesize
      @io.write json.to_slice
      @io.flush
    end

    # needs a moment to allow the settings to propagate
    sleep 500.milliseconds

    self
  end
end
