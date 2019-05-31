class EngineDriver; end

class EngineDriver::Protocol; end

class EngineDriver::Protocol::Request
  def initialize(@id, @cmd, @payload = nil, @error = nil, @backtrace = nil, @seq = nil, @reply = nil)
  end

  JSON.mapping(
    id: String,
    cmd: String,
    seq: UInt64?,
    reply: String?,
    payload: String?,
    error: String?,
    backtrace: Array(String)?
  )

  def set_error(error)
    self.payload = error.message
    self.error = error.class.to_s
    self.backtrace = error.backtrace?
    self
  end

  def build_error
    EngineDriver::RemoteException.new(self.payload, self.error, self.backtrace || [] of String)
  end
end
