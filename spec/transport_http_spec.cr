require "./helper"

describe PlaceOS::Driver::TransportHTTP do
  it "should perform a secure request" do
    queue = Helper.queue
    transport = PlaceOS::Driver::TransportHTTP.new(queue, "https://www.google.com.au/", ::PlaceOS::Driver::Settings.new("{}"))
    transport.before_request do |request|
      request.hostname.should eq "www.google.com.au"
    end
    transport.connect
    queue.online.should eq(true)

    # Make a request
    response = transport.http(:get, "/")
    response.status_code.should eq(200)

    # Close the connection
    transport.terminate
  end

  it "should perform an insecure request" do
    queue = Helper.queue

    # Selected from: https://whynohttps.com/
    transport = PlaceOS::Driver::TransportHTTP.new(queue, "http://blog.jp/", ::PlaceOS::Driver::Settings.new("{}"))
    transport.before_request do |request|
      request.hostname.should eq "blog.jp"
    end
    transport.connect
    queue.online.should eq(true)

    # Make a request
    response = transport.http(:get, "/")
    response.status_code.should eq(200)

    # Close the connection
    transport.terminate
  end
end
