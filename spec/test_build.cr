require "../src/placeos-driver"
require "promise"

class Helper
  abstract class HelperBase < PlaceOS::Driver
    def implemented_in_base_class
      self[:test] = ["bob"]
      logger.info { "testing info message" }
      puts "woot!"
    end
  end

  module IncludedAble
    def you_had_me_at_hello
      "hello"
    end
  end

  # A basic placeos driver for testing
  class TestDriver < HelperBase
    generic_name :Driver
    descriptive_name "Driver model Test"
    description "This is the driver used for testing"
    tcp_port 22

    default_settings({
      name:     "Room 123",
      username: "steve",
      password: "$encrypt",
      complex:  {
        crazy_deep: 1223,
      },
    })

    def on_load
      @username = setting(String, :username)
      @password = setting?(String, :password) || ""
    rescue
    end

    @username : String = ""
    @password : String = ""

    accessor thing : Array(Thing), implementing: IncludedAble
    accessor main_lcd : Display_1
    accessor switcher : Switcher
    accessor camera : Array(Camera), implementing: [Powerable, Moveable]
    accessor blinds : Array(Blind)?
    accessor screen : Screen?

    # cross module binding
    bind Display_1, :power, :power_changed

    # internal binding
    bind :power, :power_changed

    enum Input
      HDMI
      DisplayPort
      HDBaseT
    end

    def switch_input(input : Input)
      puts "switching to #{input}"
      input
    end

    private def power_changed(subscription, new_value)
      puts new_value
    end

    # This checks that any private methods are allowed
    private def test_private_ok(io)
      puts io
    end

    # Test error handling
    rescue_from DivisionByZeroError do |_error|
      -1
    end

    def divide_by(num : Int32)
      12 // num
    end

    # Test alternative error handling
    rescue_from IndexError, :handle_index

    protected def handle_index(_error)
      -2
    end

    def get_index(num : Int32)
      [1, 2, 3][num]
    end

    # Any method that requires a block is not included in the public API
    def add(a, &)
      a + yield
    end

    # Public API methods need to define argument types
    def add(a : Int32, b : Int32, *others)
      num = 0
      others.each { |o| num + o }
      result = a + b + num
      self[:last_added] = result
      result
    end

    # Public API will ignore splat arguments
    @[Security(Level::Support)]
    def splat_add(*splat, **dsplat)
      num = 0
      splat.each { |o| num + o }
      dsplat.values.each { |o| num + o }
      num
    end

    # using tasks and futures
    @[Security(Level::Administrator)]
    def perform_task(name : String | Int32)
      queue &.success("hello #{name}")
    end

    def error_task
      queue { raise ArgumentError.new("oops") }
    end

    def future_add(a : Int32, b : Int32 = 200)
      Promise.defer { sleep 10.milliseconds; a + b }
    end

    def future_error
      Promise.defer { raise ArgumentError.new("nooooo") }
    end

    # Other possibilities
    def raise_error
      raise ArgumentError.new("you fool!")
    end

    def not_json
      ArgumentError.new("you fool!")
    end

    # Test that HTTP methods compile
    def test_http
      get("/").status_code
    end

    # Test the SSH methods compile
    def test_exec
      exec("ls").gets_to_end
    end

    def return_false : Bool
      false
    end

    def get_system_email(proxy : Bool = false) : String?
      return config.control_system.try(&.email) unless proxy
      system.email
    end

    def received(data, task)
      response = IO::Memory.new(data).to_s
      task.try &.success(response)
    end
  end
end
