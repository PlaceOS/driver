require "../../src/placeos-driver"

# `exec` is only available when the SSH transport is compiled in,
# so this driver must fail to compile (see transport_slim_spec)
class Fixtures::HTTPOnlyNoSSH < PlaceOS::Driver
  generic_name :HTTPOnlyNoSSH
  descriptive_name "HTTP only driver referencing SSH"
  uri_base "http://example.com"

  def run_command
    exec("ls").gets_to_end
  end
end
