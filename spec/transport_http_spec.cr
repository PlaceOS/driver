require "./helper"

describe PlaceOS::Driver::TransportHTTP do
  it "should perform a secure request" do
    responses = 0
    queue = Helper.queue
    transport = PlaceOS::Driver::TransportHTTP.new(queue, "https://www.google.com/", ::PlaceOS::Driver::Settings.new(%({"disable_cookies": true}))) do
      responses += 1
    end
    transport.before_request do |request|
      request.hostname.should eq "www.google.com"
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

  # Regression guard: `transport.before_request` stores the hook in
  # `@before_request`; the underlying HTTP::Client is rotated by
  # `__new_http_client` whenever `http_max_requests` is hit (or the socket
  # is invalid, or idle longer than `keep_alive`). The hook MUST survive
  # those rotations, otherwise drivers that rely on it to inject headers
  # (e.g. Aver cam520_pro setting `Authorization: Bearer …`) would silently
  # start sending un-authed requests. `new_http_client` re-applies the
  # stored hook at lines 176-178 of transport.cr; this spec locks that in.
  it "prunes expired cookies on HTTP client rotation, preserving session and unexpired cookies" do
    server = HTTP::Server.new do |context|
      context.response.print "ok"
    end
    address = server.bind_tcp 0
    port = address.port
    spawn(same_thread: true) { server.listen }
    sleep 50.milliseconds

    queue = Helper.queue
    # max_requests: 1 forces a client rotation after each request.
    transport = PlaceOS::Driver::TransportHTTP.new(
      queue,
      "http://127.0.0.1:#{port}/",
      ::PlaceOS::Driver::Settings.new(%({"http_max_requests": 1}))
    ) { }
    transport.connect

    # Seed the jar with three cookies covering each lifecycle state.
    transport.cookies << ::HTTP::Cookie.new("expired_explicit", "v1", expires: Time.utc - 1.hour)
    transport.cookies << ::HTTP::Cookie.new("expired_maxage", "v2", max_age: 0.seconds)
    transport.cookies << ::HTTP::Cookie.new("future", "v3", expires: Time.utc + 1.hour)
    transport.cookies << ::HTTP::Cookie.new("session", "v4")
    transport.cookies.size.should eq(4)

    # Two requests at max_requests=1 → rotation happens between them.
    transport.http(:get, "/").status_code.should eq(200)
    transport.http(:get, "/").status_code.should eq(200)

    names = transport.cookies.map(&.name)
    names.should_not contain("expired_explicit")
    names.should_not contain("expired_maxage")
    names.should contain("future")
    names.should contain("session")
    transport.cookies.size.should eq(2)

    transport.terminate
    server.close
  end

  it "reapplies before_request hook after client rotation" do
    # Stand up a tiny local server so we have a deterministic endpoint
    server = HTTP::Server.new do |context|
      context.response.content_type = "text/plain"
      context.response.print "ok"
    end
    address = server.bind_tcp 0
    port = address.port
    spawn(same_thread: true) { server.listen }
    sleep 50.milliseconds

    queue = Helper.queue
    # `http_max_requests: 2` forces a client rotation between requests 2 and 3.
    transport = PlaceOS::Driver::TransportHTTP.new(
      queue,
      "http://127.0.0.1:#{port}/",
      ::PlaceOS::Driver::Settings.new(%({"disable_cookies": true, "http_max_requests": 2}))
    ) { }

    hook_calls = 0
    transport.before_request do |_request|
      hook_calls += 1
    end
    transport.connect

    # 4 requests; with max_requests=2 the underlying HTTP::Client is rotated
    # at least once. Every request must still fire the hook.
    4.times { transport.http(:get, "/").status_code.should eq(200) }

    hook_calls.should eq(4)

    transport.terminate
    server.close
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
