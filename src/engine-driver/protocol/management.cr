require "set"
require "socket"
require "promise"
require "tokenizer"
require "./request"

# Launch driver when first instance is requested
# Shutdown driver when no more instances required
class ACAEngine::Driver::Protocol::Management
  def initialize(@driver_path : String, @logger = ::Logger.new(STDOUT))
    @request_lock = Mutex.new
    @requests = {} of UInt64 => Promise::DeferredPromise(String?)
    @starting = {} of String => Promise::DeferredPromise(Nil)

    @debug_lock = Mutex.new
    @debugging = Hash(String, Array(Proc(String, Nil))).new do |hash, key|
      hash[key] = [] of Proc(String, Nil)
    end

    @tokenizer = ::Tokenizer.new do |io|
      begin
        io.read_bytes(Int32) + 4
      rescue
        0
      end
    end

    @last_exit_code = 0
    @launch_count = 0
    @launch_time = 0_i64
    @pid = -1

    @sequence = 1_u64
    @modules = {} of String => String
    @terminated = false
    @events = Channel(Request).new
    spawn(same_thread: true) { process_events }
  end

  # Core should update this callback to route requests
  property on_exec : Proc(Request, Proc(Request, Nil), Nil) = ->(request : Request, callback : Proc(Request, Nil)) {}

  getter :terminated, :logger, pid
  getter :last_exit_code, :launch_count, :launch_time
  @io : IO::Stapled? = nil

  def running?
    !!@io
  end

  def module_instances
    @modules.size
  end

  def terminate : Nil
    @events.send(Request.new("t", "terminate"))
  end

  def start(module_id : String, payload : String) : Nil
    update = false
    promise = @request_lock.synchronize do
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
      @events.send(Request.new(module_id, "start", payload))
    end
    promise.get
  end

  def update(module_id : String, payload : String) : Nil
    @events.send(Request.new(module_id, "update", payload))
  end

  def stop(module_id : String)
    @events.send(Request.new(module_id, "stop"))
  end

  def execute(module_id : String, payload : String?) : String
    promise = Promise.new(String)

    sequence = @request_lock.synchronize do
      seq = @sequence
      @sequence += 1
      @requests[seq] = promise
      seq
    end

    @events.send(Request.new(module_id, "exec", payload, seq: sequence))
    promise.get.as(String)
  end

  def debug(module_id : String, &callback : (String) -> Nil) : Nil
    count = @debug_lock.synchronize do
      array = @debugging[module_id]
      array << callback
      array.size
    end

    return unless count == 1

    @events.send(Request.new(module_id, "debug"))
  end

  def ignore(module_id : String, &callback : (String) -> Nil) : Nil
    signal = @debug_lock.synchronize do
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

    @events.send(Request.new(module_id, "ignore"))
  end

  private def process_events
    loop do
      return if @terminated
      request = @events.receive

      begin
        case request.cmd
        when "start"
          start(request)
        when "stop"
          stop(request)
        when "exec"
          exec(request.id, request.payload.not_nil!, request.seq.not_nil!)
        when "result"
          io = @io
          next unless io
          json = request.to_json
          io.write_bytes json.bytesize
          io.write json.to_slice
          io.flush
        when "debug"
          debug(request.id)
        when "ignore"
          ignore(request.id)
        when "update"
          update(request)
        when "exited"
          relaunch(request.id)
        when "terminate"
          shutdown
        end
      rescue error
        @logger.error error.inspect_with_backtrace, @driver_path
      end
    end
  end

  private def start(request : Request) : Nil
    module_id = request.id
    if @modules[module_id]?
      return update(request)
      if starting = @request_lock.synchronize { @starting.delete(module_id) }
        starting.resolve(nil)
      end
    end

    payload = request.payload.not_nil!
    @modules[module_id] = payload

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
    return unless @modules[module_id]?

    payload = request.payload.not_nil!
    @modules[module_id] = payload
    io = @io
    return unless io

    json = %({"id":"#{module_id}","cmd":"update","payload":#{payload.to_json}})
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.flush
  end

  private def stop(request : Request) : Nil
    module_id = request.id
    instance = @modules.delete module_id
    io = @io
    return unless io && instance
    return shutdown(false) if @modules.empty?

    json = %({"id":"#{module_id}","cmd":"stop"})
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.flush
  end

  private def shutdown(terminated = true) : Nil
    @terminated = terminated
    io = @io
    return unless io

    @modules.clear

    # The driver will shutdown the modules gracefully
    json = %({"id":"t","cmd":"terminate"})
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.flush
  end

  private def exec(module_id : String, payload : String, seq : UInt64) : Nil
    io = @io
    return unless io && @modules[module_id]?
    json = %({"id":"#{module_id}","cmd":"exec","seq":#{seq},"payload":#{payload.to_json}})
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.flush
  end

  private def debug(module_id : String) : Nil
    io = @io
    return unless io && @modules[module_id]?

    json = %({"id":"#{module_id}","cmd":"debug"})
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.flush
  end

  private def ignore(module_id : String) : Nil
    io = @io
    return unless io && @modules[module_id]?

    json = %({"id":"#{module_id}","cmd":"ignore"})
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.flush
  end

  # This function
  private def start_process : Nil
    return if @io || @terminated

    stdin_reader, input = IO.pipe
    output, stderr_writer = IO.pipe

    # We want to be manually flushing our writes
    input.sync = false
    io = IO::Stapled.new(output, input, true)

    @launch_count += 1
    @launch_time = Time.utc.to_unix

    fetch_pid = Promise.new(Int32)
    spawn(same_thread: true) { launch_driver(fetch_pid, stdin_reader, stderr_writer) }
    @pid = fetch_pid.get.as(Int32)

    # Start processing the output of the driver
    loaded = Promise.new(Nil)
    spawn(same_thread: true) { process_comms(io, loaded) }
    loaded.get

    # start the desired instances
    @modules.each do |module_id, payload|
      json = %({"id":"#{module_id}","cmd":"start","payload":#{payload.to_json}})
      io.write_bytes json.bytesize
      io.write json.to_slice
      io.flush
    end

    # events can now write directly to the io, driver is running
    @io = io
  end

  # launches the driver and manages the process
  private def launch_driver(fetch_pid, stdin_reader, stderr_writer) : Nil
    Process.run(
      @driver_path,
      {"-p"},
      input: stdin_reader,
      output: STDOUT,
      error: stderr_writer
    ) do |process|
      fetch_pid.resolve process.pid
    end

    status = $?
    last_exit_code = status.exit_status.to_s
    @logger.warn("driver process exited with #{last_exit_code}", @driver_path) unless status.success?
    @events.send(Request.new(last_exit_code, "exited"))
  end

  private def relaunch(last_exit_code : String) : Nil
    @io = nil
    @last_exit_code = last_exit_code.to_i
    return if @terminated
    start_process unless @modules.empty?
  end

  private def process_comms(io, loaded)
    raw_data = Bytes.new(2048)

    # wait for ready signal
    io.read_string(1)
    loaded.resolve(nil)

    while !io.closed?
      bytes_read = io.read(raw_data)
      break if bytes_read == 0 # IO was closed

      @tokenizer.extract(raw_data[0, bytes_read]).each do |message|
        string = nil
        begin
          string = String.new(message[4, message.bytesize - 4])
          # puts "recieved #{string}"
          request = Request.from_json(string)
          spawn(same_thread: true) { process(request) }
        rescue error
          @logger.warn "error parsing request #{string.inspect}\n#{error.inspect_with_backtrace}"
        end
      end
    end
  rescue IO::Error
  rescue Errno
    # Input stream closed. This should only occur on termination
  end

  private def process(request)
    case request.cmd
    when "start"
      if starting = @request_lock.synchronize { @starting.delete(request.id) }
        starting.resolve(nil)
      end
    when "result"
      seq = request.seq.not_nil!
      if promise = @request_lock.synchronize { @requests.delete(seq) }
        # determine if the result was a success or an error
        if request.error
          promise.reject request.build_error
        elsif payload = request.payload
          promise.resolve payload
        else
          promise.resolve "null"
        end
      else
        @logger.warn "sequence number #{request.seq} not found for result from #{request.id}"
      end
    when "debug"
      # pass the unparsed message down the pipe
      payload = request.payload.not_nil!
      watchers = @debug_lock.synchronize { @debugging[request.id].dup }
      watchers.each { |callback| callback.call(payload) }
    when "exec"
      # need to route this internally to the correct module
      @on_exec.call(request, ->(response : Request) {
        @events.send(response)
        nil
      })
    end
  end
end
