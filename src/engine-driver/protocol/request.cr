require "../exception"

abstract class EngineDriver; end

class EngineDriver::Protocol; end

class EngineDriver::Protocol::Request
  include JSON::Serializable

  def initialize(@id, @cmd, @payload = nil, @error = nil, @backtrace = nil, @seq = nil, @reply = nil)
  end

  property id : String
  property cmd : String
  property seq : UInt64?
  property reply : String?
  property payload : String?
  property error : String?
  property backtrace : Array(String)?

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
