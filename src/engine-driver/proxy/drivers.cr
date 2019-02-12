require "json"

class EngineDriver::Proxy::Drivers
  include Enumerable(EngineDriver::Proxy::Driver)

  def initialize(@drivers : Array(EngineDriver::Proxy::Driver))
  end

  def [](index : Int32) : EngineDriver::Proxy::Driver
    @drivers[index]
  end

  def []?(index : Int32) : EngineDriver::Proxy::Driver?
    @drivers[index]?
  end

  def size
    @drivers.size
  end

  def each
    @drivers.each do |driver|
      yield driver
    end
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

  class Responses
    def initialize(@results : Array(Concurrent::Future(JSON::Any)))
    end

    @computed : Array(JSON::Any)?

    def get : Array(JSON::Any)
      computed = @computed
      return computed if computed
      @computed = computed = @results.map &.get
      computed
    end
  end

  # Collect all the futures from the function calls and make them available to the user
  macro method_missing(call)
    results = @drivers.map do |driver|
      driver.{{call.name.id}}( {{*call.args}} {% if !call.named_args.is_a?(Nop) && call.named_args.size > 0 %}, {{**call.named_args}} {% end %} )
    end

    #}# TODO: at some point in the future use a future here. Currently blows up the compiler
    Responses.new(results)
  end
end
