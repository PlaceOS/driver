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
end
