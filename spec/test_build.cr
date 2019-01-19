require "../src/engine-driver"
require "promise"

class Helper
  # A basic engine driver for testing
  class TestDriver < EngineDriver
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

    def future_add(a : Int32, b : Int32)
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

    def received(data, task)
      response = IO::Memory.new(data).to_s
      task.try &.success(response)
    end
  end
end
