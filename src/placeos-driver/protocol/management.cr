require "promise"
require "set"
require "socket"
require "tokenizer"
require "yaml"

require "./request"

# Launch driver when first instance is requested
# Shutdown driver when no more instances required
class PlaceOS::Driver::Protocol::Management
  Log = ::Log.for(self)

  alias DebugCallback = String -> Nil

  # Core should update this callback to route requests
  property on_exec : Proc(Request, Proc(Request, Nil), Nil) = ->(_request : Request, _callback : Proc(Request, Nil)) {}
  property on_setting : Proc(String, String, YAML::Any, Nil) = ->(_module_id : String, _setting_name : String, _setting_value : YAML::Any) {}

  # A request for the system model as defined in the database
  property on_system_model : Proc(Request, Proc(Request, Nil), Nil) = ->(_request : Request, _callback : Proc(Request, Nil)) {}

  # These are the events coming from the driver where edge is expected to update redis on the drivers behalf
  enum RedisAction
    HSET
    SET
    CLEAR
    PUBLISH
  end

  property on_redis : Proc(RedisAction, String, String, String?, Nil) = ->(_action : RedisAction, _hash_id : String, _key_name : String, _status_value : String?) {}

  getter shutting_down : Channel(Nil) = Channel(Nil).new(1)
  getter? terminated : Bool = false
  getter proc : Process? = nil
  getter pid : Int64 = -1

  getter last_exit_code : Int32 = 0
  getter launch_count : Int32 = 0
  getter launch_time : Int64 = 0

  private getter tokenizer : Tokenizer = Tokenizer.new(Bytes[0x00, 0x03])

  private getter debug_lock : Mutex = Mutex.new(protection: :reentrant)
  private getter request_lock : Mutex = Mutex.new
  private getter settings_update_lock : Mutex = Mutex.new

  private getter modules : Hash(String, String) = {} of String => String
  private getter events : Channel(Request) = Channel(Request).new

  @io : UNIXSocket? = nil

  def initialize(@driver_path : String, @on_edge : Bool = false)
    @requests = {} of UInt64 => Promise::DeferredPromise(Tuple(String, Int32))
    @starting = {} of String => Promise::DeferredPromise(Nil)

    @debugging = Hash(String, Array(DebugCallback)).new do |hash, key|
      hash[key] = [] of DebugCallback
    end

    @sequence = 1_u64
    spawn(same_thread: true) { process_events }
  end

  def running?
    !!@io
  end

  def module_instances
    modules.size
  end

  def terminate : Nil
    @events.send(Request.new("t", :terminate))
  end

  def start(module_id : String, payload : String) : Nil
    update = false
    promise = request_lock.synchronize do
      prom = @starting[module_id]?
      # We want to ensure updates make it if they come in while loading
      if prom
        update = true
      else
        prom = @starting[module_id] = Promise.new(Nil)
      end
      prom
    end

    if update
      update(module_id, payload)
    else
      @events.send(Request.new(module_id, :start, payload))
    end
    promise.get
  end

  def update(module_id : String, payload : String) : Nil
    @events.send(Request.new(module_id, :update, payload))
  end

  def stop(module_id : String)
    @events.send(Request.new(module_id, :stop))
  end

  def info
    return [] of String if terminated?
    promise = Promise.new(Tuple(String, Int32))

    sequence = request_lock.synchronize do
      seq = @sequence
      @sequence = seq &+ 1
      @requests[seq] = promise
      seq
    end

    @events.send(Request.new("", :info, seq: sequence))
    Array(String).from_json promise.get[0]
  end

  def execute(module_id : String, payload : String?, user_id : String? = nil) : Tuple(String, Int32)
    raise "module #{module_id} not running, terminated" if terminated?
    promise = Promise.new(Tuple(String, Int32))

    sequence = request_lock.synchronize do
      seq = @sequence
      @sequence = seq &+ 1
      @requests[seq] = promise
      seq
    end

    @events.send(Request.new(module_id, :exec, payload, seq: sequence, user_id: user_id))
    promise.get
  end

  def debug(module_id : String, &callback : (String) -> Nil) : Nil
    count = debug_lock.synchronize do
      array = @debugging[module_id]
      array << callback
      array.size
    end

    return unless count == 1

    @events.send(Request.new(module_id, :debug))
  end

  def ignore(module_id : String, &callback : DebugCallback) : Nil
    signal = debug_lock.synchronize do
      array = @debugging[module_id]
      initial_size = array.size
      array.delete callback

      if array.size == 0
        @debugging.delete(module_id)
        initial_size > 0
      else
        false
      end
    end

    return unless signal

    @events.send(Request.new(module_id, :ignore))
  end

  # Remove all debug listeners on a module, returning the debug callback array
  #
  def ignore_all(module_id : String) : Array(DebugCallback)
    debug_lock.synchronize do
      @debugging[module_id].dup.tap do |callbacks|
        callbacks.each do |callback|
          ignore(module_id, &callback)
        end
      end
    end
  end

  # ameba:disable Metrics/CyclomaticComplexity
  private def process_events
    until terminated?
      begin
        case (request = @events.receive).cmd
        when .start?     then start(request)
        when .stop?      then stop(request)
        when .exec?      then exec(request.id, request.payload.not_nil!, request.seq.not_nil!, request.user_id)
        when .update?    then update(request)
        when .debug?     then debug(request.id)
        when .exited?    then relaunch(request.id)
        when .ignore?    then ignore(request.id)
        when .info?      then running_modules(request.seq.not_nil!)
        when .terminate? then shutdown
        when .result?
          next unless io = @io
          json = request.to_json
          io.write_bytes json.bytesize
          io.write json.to_slice
          io.flush
        else
          Log.error { "unexpected command #{request.cmd}" }
        end
      rescue error
        Log.error { {error: error.inspect_with_backtrace, driver_path: @driver_path} }
      end
    end
  end

  private def start(request : Request) : Nil
    module_id = request.id
    if modules[module_id]?
      update(request)
      starting = request_lock.synchronize { @starting.delete(module_id) }
      starting.resolve(nil) if starting

      return
    end

    payload = request.payload.not_nil!
    modules[module_id] = payload

    if io = @io
      json = %({"id":"#{module_id}","cmd":"start","payload":#{payload.to_json}})
      io.write_bytes json.bytesize
      io.write json.to_slice
      io.flush
    else
      start_process
    end
  end

  private def update(request : Request) : Nil
    module_id = request.id
    return unless modules[module_id]?

    payload = request.payload.not_nil!
    modules[module_id] = payload

    return unless io = @io

    json = %({"id":"#{module_id}","cmd":"update","payload":#{payload.to_json}})
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.flush
  end

  private def stop(request : Request) : Nil
    module_id = request.id
    instance = modules.delete module_id
    return unless (io = @io) && instance
    return shutdown(false) if modules.empty?

    json = %({"id":"#{module_id}","cmd":"stop"})
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.flush
  end

  private def shutdown(terminated = true) : Nil
    @terminated = terminated
    return unless io = @io

    modules.clear

    channel = shutting_down
    spawn(same_thread: true) { ensure_shutdown(channel) }

    # The driver will shutdown the modules gracefully
    json = %({"id":"t","cmd":"terminate"})
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.flush
  rescue
    process = proc
    return unless process
    process.terminate graceful: false
  end

  private def ensure_shutdown(channel)
    select
    when channel.receive
    when timeout 10.seconds
      if (process = proc) && channel == @shutting_down
        process.terminate graceful: false
      end
    end
  end

  private def exec(module_id : String, payload : String, seq : UInt64, user_id : String?) : Nil
    if (io = @io) && modules[module_id]?
      user_id = user_id ? %("#{user_id}") : "null"
      json = %({"id":"#{module_id}","user_id":#{user_id},"cmd":"exec","seq":#{seq},"payload":#{payload.to_json}})
      io.write_bytes json.bytesize
      io.write json.to_slice
      io.flush
    elsif promise = request_lock.synchronize { @requests.delete(seq) }
      promise.reject Exception.new("module #{module_id} not running on this host")
    end
  end

  private def debug(module_id : String) : Nil
    io = @io
    return unless io && modules[module_id]?

    json = %({"id":"#{module_id}","cmd":"debug"})
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.flush
  end

  private def ignore(module_id : String) : Nil
    return unless (io = @io) && modules[module_id]?

    json = %({"id":"#{module_id}","cmd":"ignore"})
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.flush
  end

  private def running_modules(seq : UInt64)
    if io = @io
      json = %({"id":"","cmd":"info","seq":#{seq}})
      io.write_bytes json.bytesize
      io.write json.to_slice
      io.flush
    elsif promise = request_lock.synchronize { @requests.delete(seq) }
      promise.resolve({"[]", 0})
    end
  end

  # Create the host driver process, then load modules that have been assigned.
  private def start_process : Nil
    return if @io || terminated?
    io = nil
    process = nil

    begin
      # Prepare driver IO
      unix_socket = File.tempname("pos", ".driver")
      unix_server = UNIXServer.new(unix_socket)
      wait_driver_open = Promise.new(UNIXSocket, 15.seconds)

      # no need to keep the server open once the process has checked in
      spawn do
        begin
          client = unix_server.accept
          # We want to be manually flushing our writes
          client.sync = false
          wait_driver_open.resolve client
          unix_server.close
        rescue error
          wait_driver_open.reject error
        end
      end

      @launch_count += 1
      @launch_time = Time.utc.to_unix

      fetch_proc = Promise.new(Process)
      spawn(same_thread: true) { launch_driver(fetch_proc, unix_socket) }
      @proc = process = fetch_proc.get
      @pid = process.pid

      io = wait_driver_open.get

      # Start processing the output of the driver
      loaded = Promise.new(Nil)
      spawn(same_thread: true) { process_comms(io, loaded) }
      loaded.get

      # start the desired instances
      modules.each do |module_id, payload|
        json = %({"id":"#{module_id}","cmd":"start","payload":#{payload.to_json}})
        io.write_bytes json.bytesize
        io.write json.to_slice
        io.flush
      end

      # events can now write directly to the io, driver is running
      @io = io
    rescue error
      Log.error(exception: error) { {message: "failed to launch driver", driver_path: @driver_path} }

      if io.nil?
        if process
          process.terminate graceful: false
        end

        # attempt to relaunch
        sleep 5.seconds
        return if @io || terminated?
        spawn(same_thread: true) { relaunch("-1") }
      end
    end
  end

  # launches the driver and manages the process
  private def launch_driver(fetch_proc, unix_socket) : Nil
    Process.run(
      @driver_path,
      @on_edge ? {"-p", "-e", "-s", unix_socket} : {"-p", "-s", unix_socket},
      input: Process::Redirect::Close,
      output: Process::Redirect::Inherit,
      error: Process::Redirect::Inherit
    ) do |process|
      fetch_proc.resolve process
    end

    status = $?
    last_exit_code = status.exit_code.to_s

    Log.warn { {message: "driver process exited with #{last_exit_code}", driver_path: @driver_path} } unless status.success?

    if io = @io
      @pid = -1_i64
      @proc = nil
      io.close rescue nil
      @shutting_down.send nil
      @events.send(Request.new(last_exit_code, :exited))
    end
  rescue error
    Log.error(exception: error) { "error launching driver: #{@driver_path}" }
    fetch_proc.reject error
  end

  private def relaunch(last_exit_code : String) : Nil
    @io = nil
    @pid = -1_i64
    @proc = nil
    return if terminated?
    @last_exit_code = last_exit_code.to_i? || -1

    @shutting_down = Channel(Nil).new(1)
    start_process unless modules.empty?
  end

  MESSAGE_INDICATOR = "\x00\x02"

  private def process_comms(io, loaded)
    raw_data = Bytes.new(2048)

    # wait for ready signal
    io.read_string(1)
    loaded.resolve(nil)

    until io.closed?
      bytes_read = io.read(raw_data)
      break if bytes_read == 0 # IO was closed

      # These should never be enabled in production.
      # leaving here in case protocol level debugging is required for development
      # Log.debug { "manager #{@driver_path} received #{bytes_read}" }

      tokenizer.extract(raw_data[0, bytes_read]).each do |message|
        string = nil
        begin
          string = String.new(message[0..-3])
          _junk, _, string = string.rpartition(MESSAGE_INDICATOR)

          # Log.debug do
          #  if junk.empty?
          #    "manager #{@driver_path} processing #{string}"
          #  else
          #    "manager #{@driver_path} processing #{string}, ignoring #{junk}"
          #  end
          # end

          request = Request.from_json(string)
          spawn(same_thread: true) { process(request) }
        rescue error
          Log.warn(exception: error) { "error parsing request #{string.inspect}" }
        end
      end
    end
  rescue error : IO::Error
    # Input stream closed. This should only occur on termination
    Log.debug(exception: error) { "comms closed for #{@driver_path}" } unless terminated?
    loaded.reject error
  ensure
    # Reject any pending request
    temp_reqs = request_lock.synchronize do
      reqs = @requests
      @requests = {} of UInt64 => Promise::DeferredPromise(Tuple(String, Int32))
      reqs
    end
    temp_reqs.each { |request| request.reject(Exception.new("process terminated")) }
    Log.info { "comms closed for #{@driver_path}" }
  end

  # This function is used to process comms coming from the driver
  # ameba:disable Metrics/CyclomaticComplexity
  private def process(request)
    case request.cmd
    when .start?
      if starting = request_lock.synchronize { @starting.delete(request.id) }
        starting.resolve(nil)
      end
    when .result?
      seq = request.seq.not_nil!
      if promise = request_lock.synchronize { @requests.delete(seq) }
        # determine if the result was a success or an error
        if request.error
          promise.reject request.build_error
        elsif payload = request.payload
          promise.resolve({payload, request.code || 200})
        else
          promise.resolve({"null", request.code || 200})
        end
      else
        Log.warn { "sequence number #{request.seq} not found for result from #{request.id}" }
      end
    when .debug?
      # pass the unparsed message down the pipe
      payload = request.payload.not_nil!
      watchers = debug_lock.synchronize { @debugging[request.id].dup }
      watchers.each do |callback|
        callback.call(payload)
      rescue error
        Log.warn(exception: error) { "error forwarding debug payload #{request.inspect}" }
      end
    when .exec?
      # need to route this internally to the correct module
      on_exec.call(request, ->(response : Request) {
        # The event queue is for sending data to the driver
        response.cmd = :result
        @events.send(response)
        nil
      })
    when .sys?
      # the response payload should return the requested systems database model
      on_system_model.call(request, ->(response : Request) {
        response.cmd = :result
        @events.send(response)
        nil
      })
    when .setting?
      mod_id = request.id
      setting_name, setting_value = Tuple(String, YAML::Any).from_yaml(request.payload.as(String))
      settings_update_lock.synchronize { on_setting.call(mod_id, setting_name, setting_value) }
    when .hset?
      # Redis proxy driver state (hash)
      hash_id = request.id
      key, value = request.payload.not_nil!.split("\x03", 2)
      on_redis.call(RedisAction::HSET, hash_id, key, value.empty? ? "null" : value)
    when .set?
      # Redis proxy key / value
      key = request.id
      value = request.payload.not_nil!
      on_redis.call(RedisAction::SET, key, value, nil)
    when .clear?
      hash_id = request.id
      on_redis.call(RedisAction::CLEAR, hash_id, "clear", nil)
    when .publish?
      channel = request.id
      value = request.payload.not_nil!
      on_redis.call(RedisAction::PUBLISH, channel, value, nil)
    else
      Log.warn { "unexpected command in process events #{request.cmd}" }
    end
  rescue error
    Log.warn(exception: error) { "error processing driver request #{request.inspect}" }
  end
end
