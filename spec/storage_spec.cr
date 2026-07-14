require "./helper"

describe PlaceOS::Driver::RedisStorage do
  it "should perform basic storage operations" do
    store = PlaceOS::Driver::RedisStorage.new("test-123")
    store.size.should eq(0)
    store[:test] = "null"
    store.size.should eq(0)

    store[:test] = "true"
    store.size.should eq(1)

    store[:test].should eq("true")
    store.delete(:test).should eq("true")
    store.size.should eq(0)

    store[:test] = "true"
    store.size.should eq(1)

    store[:test] = "null"
    store.size.should eq(0)

    store[:what]?.should eq(nil)
  end

  it "should return keys and values" do
    store = PlaceOS::Driver::RedisStorage.new("test-123")
    store[:test] = "true"
    store[:other] = "1234"
    store.size.should eq(2)

    store.keys.should eq(["test", "other"])
    store.values.should eq(["true", "1234"])

    vals = ["test", "true", "other", "1234"]
    store.each do |key, value|
      keyc = vals.shift
      valuec = vals.shift

      key.should eq(keyc)
      value.should eq(valuec)
    end

    store.empty?.should eq(false)

    store.clear
    store.size.should eq(0)

    store.empty?.should eq(true)
  end

  it "should generate a crystal hash" do
    store = PlaceOS::Driver::RedisStorage.new("test-123")
    store[:test] = "true"
    store[:other] = "1234"
    store.size.should eq(2)
    store.to_h.should eq({
      "test"  => "true",
      "other" => "1234",
    })
    store.clear
    store.size.should eq(0)
  end

  it "should set a value with an expiry (Time::Span and seconds)" do
    store = PlaceOS::Driver::RedisStorage.new("test-expire")
    store.clear

    # Time::Span ttl
    store.set_expire(:presence, "true", 60.seconds)
    store[:presence].should eq("true")
    ttl = PlaceOS::Driver::RedisStorage.with_redis(&.httl("status/test-expire", "presence")).first
    ttl.should be_a(Int64)
    ttl.as(Int64).should be > 0
    ttl.as(Int64).should be <= 60

    # integer seconds ttl
    store.set_expire(:other, "1234", 120)
    store[:other].should eq("1234")
    ttl2 = PlaceOS::Driver::RedisStorage.with_redis(&.httl("status/test-expire", "other")).first.as(Int64)
    ttl2.should be > 60
    ttl2.should be <= 120

    # a "null" value deletes the field
    store.set_expire(:presence, "null", 60.seconds)
    store[:presence]?.should eq(nil)

    store.clear
  end

  it "should reset the expiry without changing the value" do
    store = PlaceOS::Driver::RedisStorage.new("test-expire")
    store.clear

    store.set_expire(:presence, "here", 10.seconds)
    store[:presence].should eq("here")

    # resetting an existing field's expiry returns true and leaves the value intact
    store.expire(:presence, 300.seconds).should eq(true)
    store[:presence].should eq("here")
    ttl = PlaceOS::Driver::RedisStorage.with_redis(&.httl("status/test-expire", "presence")).first.as(Int64)
    ttl.should be > 60

    # resetting a missing field returns false
    store.expire(:missing, 30.seconds).should eq(false)

    store.clear
  end

  it "publishes on set_expire only when requested" do
    module_id = "test-expire-pub-#{Random.new.hex(4)}"
    store = PlaceOS::Driver::RedisStorage.new(module_id)
    store.clear

    fired = Channel(String).new(1)
    subs = PlaceOS::Driver::Subscriptions.new
    subs.subscribe(module_id, :presence) { |_sub, message| fired.send(message) }

    # publish: true notifies subscribers of the new value
    store.set_expire(:presence, "here", 60.seconds, publish: true)
    select
    when message = fired.receive
      message.should eq("here")
    when timeout(1.second)
      fail "expected a published message when publish: true"
    end

    # publish: false (the default) still sets the value + ttl, but silently
    store.set_expire(:presence, "there", 60.seconds)
    store[:presence].should eq("there")
    PlaceOS::Driver::RedisStorage.with_redis(&.httl("status/#{module_id}", "presence")).first.as(Int64).should be > 0
    select
    when message = fired.receive
      fail "did not expect a published message when publish: false, got #{message.inspect}"
    when timeout(300.milliseconds)
      # success — nothing was published
    end

    store.clear
    subs.terminate
  end
end
