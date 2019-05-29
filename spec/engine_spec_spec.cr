require "./helper"

describe EngineSpec do
  it "should be able to load a compiled driver for mocking" do
    # Compile the driver
    `crystal build ./spec/test_build.cr`

    # Test spec'ing a driver
    EngineSpec.mock_driver("Helper::TestDriver", "./test_build") do
      exec(:implemented_in_base_class)
    end
  end
end
