require "json"

require "./driver"

class PlaceOS::Driver::Proxy::Drivers
  include Enumerable(PlaceOS::Driver::Proxy::Driver)

  def initialize(@drivers : Array(PlaceOS::Driver::Proxy::Driver))
  end

  def [](index : Int32) : PlaceOS::Driver::Proxy::Driver
    @drivers[index]
  end

  def []?(index : Int32) : PlaceOS::Driver::Proxy::Driver?
    @drivers[index]?
  end

  def size
    @drivers.size
  end

  def each(&)
    @drivers.each do |driver|
      yield driver
    end
  end

  # This deliberately prevents compilation if called from driver code
  def []=(status, value)
    {{ raise "Remote drivers are read only. Please use the public interface to modify state" }}
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
  def subscribe(status, &_callback : (PlaceOS::Driver::Subscriptions::IndirectSubscription, String) -> Nil) : PlaceOS::Driver::Subscriptions::IndirectSubscription
    {{ raise "Can't subscribe to state on a collection of drivers" }}
  end

  class Responses
    def initialize(@results : Array(::Future::Compute(JSON::Any)))
    end

    @computed : Array(JSON::Any)?

    def get(raise_on_error : Bool = false) : Array(JSON::Any)
      computed = @computed
      return computed if computed
      @computed = computed = @results.compact_map do |result|
        begin
          result.get
        rescue error
          raise error if raise_on_error
          nil
        end
      end
      computed
    end
  end

  # Collect all the futures from the function calls and make them available to the user
  macro method_missing(call)
    results = @drivers.map do |driver|
      begin
        driver.{{call.name.id}}( {{*call.args}} {% if !call.named_args.is_a?(Nop) && call.named_args.size > 0 %}, {{**call.named_args}} {% end %} )
      rescue error
        ::Future::Compute(JSON::Any).new(false) { raise error }
      end
    end

    #}# TODO: at some point in the future use a future here. Currently blows up the compiler
    Responses.new(results)
  end
end
