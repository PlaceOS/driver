require "json"

require "./driver"

struct PlaceOS::Driver::Proxy::Responses
  def initialize(@results : Array(ExecResponse))
  end

  getter results : Array(ExecResponse)

  def get_json(raise_on_error : Bool = false) : String
    String.build do |str|
      str << '['
      size = 0
      @results.each do |result|
        begin
          str << result.get_json
          str << ','
          size += 1
        rescue error
          # error will have been logged on the remote so no need to here as well
          raise error if raise_on_error
        end
      end
      str.back(1) unless size.zero?
      str << ']'
    end
  end

  def get(raise_on_error : Bool = false) : Array(JSON::Any)
    Array(JSON::Any).from_json(get_json(raise_on_error))
  end
end

struct PlaceOS::Driver::Proxy::Drivers
  include Enumerable(PlaceOS::Driver::Proxy::Driver)

  # for backwards compatibility
  alias Responses = PlaceOS::Driver::Proxy::Responses

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

  # Collect all the futures from the function calls and make them available to the user
  macro method_missing(call)
    results = @drivers.map do |driver|
      begin
        driver.{{call.name.id}}( {{call.args.splat}} {% if !call.named_args.is_a?(Nop) && call.named_args.size > 0 %}, {{call.named_args.double_splat}} {% end %} )
      rescue error
        ExecResponse.new(lazy { raise error; "" })
      end
    end

    #}# TODO: at some point in the future use a future here. Currently blows up the compiler
    Responses.new(results)
  end
end
