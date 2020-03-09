require "./helper"

describe PlaceOS::Driver::Queue do
  it "should process task with response" do
    queue = Helper.queue
    queue.online = true

    t = queue.add do |task|
      task.success 1234
    end
    t.response_required!
    result = t.get
    queue.terminate

    result.state.should eq :success
    result.payload.should eq "1234"
    result.backtrace.should eq([] of String)
    result.error_class.should eq nil

    # Slightly different way to indicate if a response is required
    queue = Helper.queue
    queue.online = true

    t = queue.add do |task|
      task.success 1234
    end
    result = t.get :response_required
    queue.terminate

    result.state.should eq :success
    result.payload.should eq "1234"
    result.backtrace.should eq([] of String)
    result.error_class.should eq nil
  end

  it "should process task with default response" do
    queue = Helper.queue
    queue.online = true

    t = queue.add do |task|
      task.success 1234
    end

    result = t.get
    queue.terminate

    result.state.should eq :success
    result.payload.should eq "null"
    result.backtrace.should eq([] of String)
    result.error_class.should eq nil
  end

  it "should process task with default response" do
    queue = Helper.queue
    queue.online = true

    t = queue.add do |task|
      task.success 1234
    end

    result = t.get
    queue.terminate

    result.state.should eq :success
    result.payload.should eq "null"
    result.backtrace.should eq([] of String)
    result.error_class.should eq nil
  end

  it "should process multiple tasks" do
    queue = Helper.queue
    queue.online = true

    t1 = queue.add { |task|
      task.success 50
    }.response_required!

    t2 = queue.add priority: 100 { |task|
      task.success 100
    }.response_required!

    result = t2.get
    result.state.should eq :success
    result.payload.should eq "100"
    result.backtrace.should eq([] of String)
    result.error_class.should eq nil

    result = t1.get
    result.state.should eq :success
    result.payload.should eq "50"
    result.backtrace.should eq([] of String)
    result.error_class.should eq nil

    queue.terminate
  end

  it "should retry a task if a timeout occurs" do
    queue = Helper.queue
    queue.online = true

    count = 0

    t = queue.add(timeout: 5.milliseconds) { |task|
      count += 1
      task.success(1234) if count > 2
    }.response_required!

    result = t.get
    queue.terminate

    count.should eq(3)

    result.state.should eq :success
    result.payload.should eq "1234"
    result.backtrace.should eq([] of String)
    result.error_class.should eq nil
  end

  it "should fail a task with abort if retries fail" do
    queue = Helper.queue
    queue.online = true

    count = 0

    t = queue.add(timeout: 5.milliseconds) {
      count += 1
    }.response_required!

    result = t.get
    queue.terminate

    count.should eq(4)

    result.state.should eq :abort
    result.payload.should eq "retry limit reached (due to timeout)"
    result.backtrace.should eq([] of String)
    result.error_class.should eq nil
  end

  it "should return an exception if an error occurs running the task" do
    queue = Helper.queue
    queue.online = true

    t = queue.add {
      raise "error"
    }

    result = t.get
    queue.terminate

    result.state.should eq :exception
    result.payload.should eq "error"
    (result.backtrace.size > 0).should eq(true)
  end

  it "should allow for connected state to be updated" do
    std_out = IO::Memory.new
    logger = ::Logger.new(std_out)
    connected = false
    queue = PlaceOS::Driver::Queue.new(logger) { |state| connected = state }

    connected.should eq(false)
    queue.online = true
    connected.should eq(true)
    queue.online = false
    connected.should eq(false)

    # Since we already update connected state via the queue, we might as well
    # make this the path for manually updating the state in a driver
    queue.set_connected(true)
    connected.should eq(true)
  end
end
