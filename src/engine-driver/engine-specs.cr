class EngineSpec
  def self.mock_driver(driver_name)
    # Load the driver
    driver_exec = ENV["SPEC_RUN_DRIVER"]

    # Start comms

    # initialise the comms

    # Run the spec
    spec = EngineSpec.new
    with spec yield

    # Run any clean up
  end
end
