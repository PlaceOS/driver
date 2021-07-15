require "./helper"

describe PlaceOS::Driver::Proxy::Scheduler do
  it "should wrap Tasker objects so we can effectively track them" do
    sched = PlaceOS::Driver::Proxy::Scheduler.new
    ran = false
    sched.at(40.milliseconds.from_now) { ran = true }

    sleep 20.milliseconds
    sched.size.should eq(1)
    ran.should eq(false)

    sleep 40.milliseconds
    ran.should eq(true)
    sched.size.should eq(0)
  end

  it "should cancel Tasker objects" do
    sched = PlaceOS::Driver::Proxy::Scheduler.new
    ran = false
    sched.at(40.milliseconds.from_now) { ran = true }

    sleep 20.milliseconds
    sched.size.should eq(1)
    ran.should eq(false)

    sched.clear
    sched.size.should eq(0)

    sleep 40.milliseconds
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
    expect_raises(Exception, "was error") do
      task.get
      raise "not here"
    end

    # Test cancellation
    task = sched.at(20.milliseconds.from_now) { true }
    spawn(same_thread: true) { task.cancel }
    expect_raises(Exception, "Task cancelled") do
      task.get
      raise "failed"
    end
  end

  it "should schedule a repeating task" do
    sched = PlaceOS::Driver::Proxy::Scheduler.new
    ran = 0
    task = sched.every(32.milliseconds) { ran += 1 }

    sleep 16.milliseconds
    sched.size.should eq(1)
    ran.should eq(0)

    sleep 24.milliseconds
    ran.should eq(1)
    sched.size.should eq(1)

    sleep 32.milliseconds
    ran.should eq(2)
    sched.size.should eq(1)

    sleep 32.milliseconds
    ran.should eq(3)
    sched.size.should eq(1)

    task.cancel
    sched.size.should eq(0)
  end

  it "should schedule a repeating task and a single task" do
    sched = PlaceOS::Driver::Proxy::Scheduler.new
    ran = 0
    single = 0
    sched.in(32.milliseconds) { single += 1 }
    task = sched.every(64.milliseconds) { ran += 1 }

    sleep 48.milliseconds
    sched.size.should eq(1)
    ran.should eq(0)
    single.should eq(1)

    sleep 32.milliseconds
    ran.should eq(1)
    sched.size.should eq(1)

    sleep 64.milliseconds
    ran.should eq(2)
    sched.size.should eq(1)

    sleep 64.milliseconds
    ran.should eq(3)
    sched.size.should eq(1)

    task.cancel
    sched.size.should eq(0)
  end

  it "should pause and resume a repeating task" do
    sched = PlaceOS::Driver::Proxy::Scheduler.new
    ran = 0
    task = sched.every(24.milliseconds) { ran += 1; ran }

    sleep 36.milliseconds
    ran.should eq(1)
    sched.size.should eq(1)

    sleep 24.milliseconds
    ran.should eq(2)
    sched.size.should eq(1)

    task.cancel
    sched.size.should eq(0)

    sleep 24.milliseconds
    ran.should eq(2)
    sched.size.should eq(0)

    task.resume
    sched.size.should eq(1)

    sleep 36.milliseconds
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
    expect_raises(Exception, "some error") do
      task.get.should eq 4
      raise "failed"
    end
    task.get.should eq 5

    # Test cancelation
    spawn(same_thread: true) { task.cancel }
    expect_raises(Exception, "Task cancelled") do
      task.get
    end
  end
end
