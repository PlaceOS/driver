require "./placeos-driver"

# include all the transports in the generated documentation
PlaceOS::Driver.load_all_transports

# :nodoc:
class DocDriver < PlaceOS::Driver
  generic_name :Driver
  descriptive_name "Driver model Test"
  description "This is the driver used for testing"
end
