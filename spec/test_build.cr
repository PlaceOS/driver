require "../src/engine-driver"
require "promise"

class Helper
  abstract class HelperBase < EngineDriver
    def implemented_in_base_class
      self[:test] = ["bob"]
      puts "woot!"
    end
  end

  module IncludedAble
    def you_had_me_at_hello
      "hello"
    end
  end

  # A basic engine driver for testing
  class TestDriver < HelperBase
    generic_name :Driver
    descriptive_name "Driver model Test"
    description "This is the driver used for testing"
    tcp_port 22
    makebreak!
    default_settings({
      name:     "Room 123",
      username: "steve",
      password: "$encrypt",
      complex:  {
        crazy_deep: 1223,
      },
    })

    accessor thing : Thing, implementing: IncludedAble
    accessor main_lcd : Display_1, implementing: Powerable
    accessor switcher : Switcher
    accessor camera : Array(Camera), implementing: [Powerable, Moveable]
    accessor blinds : Array(Blind)?
    accessor screen : Screen?

    # cross module binding
    bind Display_1, :power, :power_changed

    # internal binding
    bind :power, :power_changed

    private def power_changed(subscription, new_value)
      puts new_value
    end

    # This checks that any private methods are allowed
    private def test_private_ok(io)
      puts io
    end

    # Any method that requires a block is not included in the public API
    def add(a)
      a + yield
    end

    # Public API methods need to define argument types
    def add(a : Int32, b : Int32, *others)
      num = 0
      others.each { |o| num + o }
      a + b + num
    end

    # Public API will ignore splat arguments
    def splat_add(*splat, **dsplat)
      num = 0
      splat.each { |o| num + o }
      dsplat.values.each { |o| num + o }
      num
    end

    # using tasks and futures
    def perform_task(name : String)
      queue &.success("hello #{name}")
    end

    def error_task
      queue { raise ArgumentError.new("oops") }
    end

    def future_add(a : Int32, b : Int32 = 200)
      Promise.defer { sleep 0.01; a + b }
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

    def received(data, task)
      response = IO::Memory.new(data).to_s
      task.try &.success(response)
    end
  end
end
