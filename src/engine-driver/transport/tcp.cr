require "socket"

class EngineDriver::TransportTCP < EngineDriver::Transport
  # timeouts in seconds
  def initialize(@queue : EngineDriver::Queue, @ip : String, @port : Int32, &@received : (Bytes, EngineDriver::Task?) -> Nil)
    @terminated = false
    @logger = @queue.logger
  end

  @logger : ::Logger
  @socket : TCPSocket?
  property :received
  getter :logger

  def connect(connect_timeout : Int32 = 10)
    return if @terminated
    if socket = @socket
      return unless socket.closed?
    end

    retry max_interval: 10.seconds do
      socket = @socket = TCPSocket.new(@ip, @port, connect_timeout: connect_timeout)
      socket.tcp_nodelay = true

      # Enable queuing
      @queue.online = true

      # Start consuming data from the socket
      spawn { consume_io }
    end
  end

  def terminate
    @terminated = true
    @socket.try &.close
  end

  def send(message) : Int32
    socket = @socket
    return 0 if socket.nil? || socket.closed?
    data = message.to_slice
    socket.write data
    return data.size
  end

  def send(message, task : EngineDriver::Task, &block : Bytes -> Nil) : Int32
    socket = @socket
    return 0 if socket.nil? || socket.closed?
    task.processing = block
    data = message.to_slice
    socket.write data
    return data.size
  end

  private def consume_io
    raw_data = Bytes.new(2048)
    if socket = @socket
      while !socket.closed?
        bytes_read = socket.read(raw_data)
        break if bytes_read == 0 # IO was closed

        data = raw_data[0, bytes_read]
        spawn { process(data) }
      end
    end
  rescue IO::Error | Errno
  rescue error
    @logger.error "error consuming IO\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
  ensure
    connect
  end

  private def process(data) : Nil
    # Check if the task provided a response processing block
    if task = @queue.current
      if processing = task.processing
        processing.call(data)
        return
      end
    end

    # See spec for how this callback is expected to be used
    @received.call(data, @queue.current)

  rescue error
    @logger.error "error processing received data\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
  end
end
