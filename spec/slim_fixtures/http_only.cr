require "../../src/placeos-driver"

# a service driver should only compile in the HTTP and websocket transports
class Fixtures::HTTPOnly < PlaceOS::Driver
  generic_name :HTTPOnly
  descriptive_name "HTTP only driver"
  uri_base "http://example.com"

  def query
    get("/").status_code
  end
end
