require "./helper"
require "../src/driver/driver-specs/runner"

describe DriverSpecs do
  it "should be able to load a compiled driver for mocking" do
    # Compile the driver
    `crystal build ./spec/test_build.cr`

    # Test spec'ing a driver
    DriverSpecs.mock_driver("Helper::TestDriver", "./test_build") do
      transmit "testing\n"
      response = exec(:implemented_in_base_class)

      # Waits for a response from the function
      response.get.should eq(nil)

      # Test the expected value was set in redis
      status[:test][0].should eq("bob")
    end
  end
end
