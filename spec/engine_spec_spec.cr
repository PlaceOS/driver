require "./helper"
require "../src/engine-driver/engine-specs/runner"

describe EngineSpec do
  it "should be able to load a compiled driver for mocking" do
    # Compile the driver
    `crystal build ./spec/test_build.cr`

    # Test spec'ing a driver
    EngineSpec.mock_driver("Helper::TestDriver", "./test_build") do
      response = exec(:implemented_in_base_class).get
      response.should eq(nil)
      status[:test][0].should eq("bob")
    end
  end
end
