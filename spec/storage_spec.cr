require "./helper"

describe EngineDriver::Storage do
  it "should perform basic storage operations" do
    store = EngineDriver::Storage.new("test-123")
    store.size.should eq(0)
    store[:test] = "null"
    store.size.should eq(1)
    store[:test].should eq("null")
    store.delete(:test).should eq("null")
    store.size.should eq(0)

    store[:test] = "null"
    store.size.should eq(1)

    store[:test] = nil
    store.size.should eq(0)

    store[:what]?.should eq(nil)
  end

  it "should return keys and values" do
    store = EngineDriver::Storage.new("test-123")
    store[:test] = "null"
    store[:other] = "1234"
    store.size.should eq(2)

    store.keys.should eq(["test", "other"])
    store.values.should eq(["null", "1234"])

    vals = ["test", "null", "other", "1234"]
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
    store = EngineDriver::Storage.new("test-123")
    store[:test] = "null"
    store[:other] = "1234"
    store.size.should eq(2)
    store.to_h.should eq({
      "test"  => "null",
      "other" => "1234",
    })
    store.clear
    store.size.should eq(0)
  end
end
