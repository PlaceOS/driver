require "./helper"

describe PlaceOS::Driver::Proxy::Scheduler do
  it "should wrap Tasker objects so we can effectively track them" do
    sched = PlaceOS::Driver::Proxy::Scheduler.new
    ran = false
    sched.at(2.milliseconds.from_now) { ran = true }

    sleep 1.milliseconds
    sched.size.should eq(1)
    ran.should eq(false)

    sleep 2.milliseconds
    ran.should eq(true)
    sched.size.should eq(0)
  end

  it "should cancel Tasker objects" do
    sched = PlaceOS::Driver::Proxy::Scheduler.new
    ran = false
    sched.at(2.milliseconds.from_now) { ran = true }

    sleep 1.milliseconds
    sched.size.should eq(1)
    ran.should eq(false)

    sched.clear
    sched.size.should eq(0)

    sleep 2.milliseconds
    ran.should eq(false)
    sched.size.should eq(0)
  end

  it "should be possible to obtain the return value of the task" do
    sched = PlaceOS::Driver::Proxy::Scheduler.new

    # Test execution
    task = sched.at(2.milliseconds.from_now) { true }
    task.get.should eq true

    # Test failure
    task = sched.at(2.milliseconds.from_now) { raise "was error" }
    begin
      task.get
      raise "not here"
    rescue error
      error.message.should eq "was error"
    end

    # Test cancelation
    task = sched.at(2.milliseconds.from_now) { true }
    spawn(same_thread: true) { task.cancel }
    begin
      task.get
      raise "failed"
    rescue error
      error.message.should eq "Task canceled"
    end
  end

  it "should schedule a repeating task" do
    sched = PlaceOS::Driver::Proxy::Scheduler.new
    ran = 0
    task = sched.every(4.milliseconds) { ran += 1 }

    sleep 2.milliseconds
    sched.size.should eq(1)
    ran.should eq(0)

    sleep 3.milliseconds
    ran.should eq(1)
    sched.size.should eq(1)

    sleep 4.milliseconds
    ran.should eq(2)
    sched.size.should eq(1)

    sleep 4.milliseconds
    ran.should eq(3)
    sched.size.should eq(1)

    task.cancel
    sched.size.should eq(0)
  end

  it "should schedule a repeating task and a single task" do
    sched = PlaceOS::Driver::Proxy::Scheduler.new
    ran = 0
    single = 0
    sched.in(2.milliseconds) { single += 1 }
    task = sched.every(4.milliseconds) { ran += 1 }

    sleep 3.milliseconds
    sched.size.should eq(1)
    ran.should eq(0)
    single.should eq(1)

    sleep 2.milliseconds
    ran.should eq(1)
    sched.size.should eq(1)

    sleep 4.milliseconds
    ran.should eq(2)
    sched.size.should eq(1)

    sleep 4.milliseconds
    ran.should eq(3)
    sched.size.should eq(1)

    task.cancel
    sched.size.should eq(0)
  end

  it "should pause and resume a repeating task" do
    sched = PlaceOS::Driver::Proxy::Scheduler.new
    ran = 0
    task = sched.every(2.milliseconds) { ran += 1; ran }

    sleep 3.milliseconds
    ran.should eq(1)
    sched.size.should eq(1)

    sleep 2.milliseconds
    ran.should eq(2)
    sched.size.should eq(1)

    task.cancel
    sched.size.should eq(0)

    sleep 2.milliseconds
    ran.should eq(2)
    sched.size.should eq(0)

    task.resume
    sched.size.should eq(1)

    sleep 3.milliseconds
    ran.should eq(3)
    sched.size.should eq(1)

    task.cancel
  end

  it "should be possible to obtain the next value of a repeating" do
    sched = PlaceOS::Driver::Proxy::Scheduler.new
    ran = 0
    task = sched.every(2.milliseconds) do
      ran += 1
      raise "some error" if ran == 4
      ran
    end

    # Test execution
    task.get.should eq 1
    task.get.should eq 2
    task.get.should eq 3
    begin
      task.get.should eq 4
      raise "failed"
    rescue error
      error.message.should eq "some error"
    end
    task.get.should eq 5

    # Test cancelation
    spawn(same_thread: true) { task.cancel }
    begin
      task.get
      raise "failed"
    rescue error
      error.message.should eq "Task canceled"
    end
  end
end
