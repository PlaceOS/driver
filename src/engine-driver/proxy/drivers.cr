require "json"
require "promise"

class EngineDriver::Proxy::Drivers
  def initialize(
    @system : EngineDriver::Proxy::System,
    @drivers : Array(EngineDriver::Proxy::Driver)
  )
  end

  def [](index : Int32) : EngineDriver::Proxy::Driver
    @drivers[index]
  end

  def []?(index : Int32) : EngineDriver::Proxy::Driver?
    @drivers[index]?
  end

  # This deliberately prevents compilation if called from driver code
  def []=(status, value)
    {{ "Remote drivers are read only. Please use the public interface to modify state".id }}
  end

  def implements?(interface) : Bool
    # if drivers is an empty array then we want to return false
    does = false
    interface = interface.to_s
    @drivers.each do |driver|
      if driver.implements?(interface)
        does = true
      else
        does = false
        break
      end
    end
    does
  end

  # This deliberately prevents compilation if called from driver code
  def subscribe(status, &callback : (EngineDriver::Subscriptions::IndirectSubscription, String) -> Nil) : EngineDriver::Subscriptions::IndirectSubscription
    {{ "Can't subscribe to state on a collection of drivers".id }}
  end

  # Collect all the promises from the function calls and make them available to the user
  macro method_missing(call)
    promises = @drivers.map do |driver|
      driver.{{call.name.id}}( {{*call.args}} {% if !call.named_args.is_a?(Nop) && call.named_args.size > 0 %}, {{**call.named_args}} {% end %} )
    end

    Promise.all(promises)
  end
end
