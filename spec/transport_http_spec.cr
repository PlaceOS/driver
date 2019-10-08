require "./helper"

describe ACAEngine::Driver::TransportHTTP do
  it "should perform a secure request" do
    queue = Helper.queue
    transport = ACAEngine::Driver::TransportHTTP.new(queue, "https://www.google.com.au/", ::ACAEngine::Driver::Settings.new("{}"))
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
    transport = ACAEngine::Driver::TransportHTTP.new(queue, "http://blog.jp/", ::ACAEngine::Driver::Settings.new("{}"))
    transport.connect
    queue.online.should eq(true)

    # Make a request
    response = transport.http(:get, "/")
    response.status_code.should eq(200)

    # Close the connection
    transport.terminate
  end
end
