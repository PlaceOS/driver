class EngineSpec; end

class EngineSpec::Responder
  def initialize
    @channel = Channel(PlaceOS::Driver::Protocol::Request).new(1)
  end

  getter channel

  def get
    request = @channel.receive
    if request.error
      raise request.build_error
    elsif payload = request.payload
      JSON.parse(payload)
    else
      nil
    end
  end
end
