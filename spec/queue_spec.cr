require "./helper"

describe EngineDriver::Queue do
  it "should process task with response" do
    queue = Helper.queue
    queue.online = true

    t = queue.add do |task|
      task.success 1234
    end
    t.response_required!
    result = t.get
    queue.terminate

    result.should eq({
      result: :success,
      payload: "[1234]",
      backtrace: [] of String
    })

    # Slightly different way to indicate if a response is required
    queue = Helper.queue
    queue.online = true

    t = queue.add do |task|
      task.success 1234
    end
    result = t.get :response_required
    queue.terminate

    result.should eq({
      result: :success,
      payload: "[1234]",
      backtrace: [] of String
    })
  end

  it "should process task with default response" do
    queue = Helper.queue
    queue.online = true

    t = queue.add do |task|
      task.success 1234
    end

    result = t.get
    queue.terminate

    result.should eq({
      result: :success,
      payload: "[null]",
      backtrace: [] of String
    })
  end

  it "should process task with default response" do
    queue = Helper.queue
    queue.online = true

    t = queue.add do |task|
      task.success 1234
    end

    result = t.get
    queue.terminate

    result.should eq({
      result: :success,
      payload: "[null]",
      backtrace: [] of String
    })
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
    result.should eq({
      result: :success,
      payload: "[100]",
      backtrace: [] of String
    })

    result = t1.get
    result.should eq({
      result: :success,
      payload: "[50]",
      backtrace: [] of String
    })

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

    result.should eq({
      result: :success,
      payload: "[1234]",
      backtrace: [] of String
    })
  end

  it "should fail a task with abort if retries fail" do
    queue = Helper.queue
    queue.online = true

    count = 0

    t = queue.add(timeout: 5.milliseconds) { |task|
      count += 1
    }.response_required!

    result = t.get
    queue.terminate

    count.should eq(4)

    result.should eq({
      result: :abort,
      payload: "retries failed",
      backtrace: [] of String
    })
  end

  it "should return an exception if an error occurs running the task" do
    queue = Helper.queue
    queue.online = true

    t = queue.add { |task|
      raise "error"
    }

    result = t.get
    queue.terminate

    result[:result].should eq(:exception)
    result[:payload].should eq("error")
    (result[:backtrace].size > 0).should eq(true)
  end
end
