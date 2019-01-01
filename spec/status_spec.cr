require "./helper"

describe EngineDriver::Status do
  it "should convert values to JSON during assignment" do
    status = EngineDriver::Status.new
    status.set_json(:bob, 1234)
    status.fetch_json(:bob).as_i.should eq(1234)
    status["bob"].should eq("1234")
  end

  it "should allow for nil values" do
    status = EngineDriver::Status.new
    status.fetch_json?(:jane).should eq(nil)
  end

  it "should allow for default values, except these should return as JSON any" do
    status = EngineDriver::Status.new
    status.fetch_json(:jane) { 123 }.as_i.should eq(123)
  end
end
