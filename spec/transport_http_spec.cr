require "./helper"

describe PlaceOS::Driver::TransportHTTP do
  it "should perform a secure request" do
    responses = 0
    queue = Helper.queue
    transport = PlaceOS::Driver::TransportHTTP.new(queue, "https://www.google.com.au/", ::PlaceOS::Driver::Settings.new(%({"disable_cookies": true}))) do
      responses += 1
    end
    transport.before_request do |request|
      request.hostname.should eq "www.google.com.au"
    end
    transport.connect
    queue.online.should eq(true)

    # Make a request
    response = transport.http(:get, "/")
    response.status_code.should eq(200)
    transport.cookies.size.should eq 0
    responses.should eq 1

    # Close the connection
    transport.terminate
  end

  it "should perform an insecure request" do
    queue = Helper.queue
    responses = 0
    # Selected from: https://whynohttps.com/
    transport = PlaceOS::Driver::TransportHTTP.new(queue, "http://blog.jp/", ::PlaceOS::Driver::Settings.new("{}")) do
      responses += 1
    end
    transport.before_request do |request|
      request.hostname.should eq "blog.jp"
    end
    transport.connect
    queue.online.should eq(true)

    # Make a request
    response = transport.http(:get, "/")
    response.status_code.should eq(200)
    (transport.cookies.size > 0).should be_true
    responses.should eq 1

    # Close the connection
    transport.terminate
  end
end
