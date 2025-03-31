require "http"
require "./http_proxy"

require "../transport"

class PlaceOS::Driver
  {% for method in %w(get post put head delete patch options) %}
    # Executes a {{method.id.upcase}} request on the client connection.
    #
    # The response status will be automatically checked and an error raised if unsuccessful
    #
    # Macro expansion allows this to obtain context from a surround method and
    # use method arguments to build an appropriate request structure.
    #
    # Us *as* to specify a JSON parse-able model that the response should be
    # piped into. If unspecified a `JSON::Any` will be returned.
    private macro {{method.id}}_request(path, params = URI::Params.new, headers = HTTP::Headers.new, body = nil, secure = false, concurrent = false, as model = nil)
      {% verbatim do %}
        path = {{path}}
        headers = {{headers}}

        # Build a body (if required)
        {% if body.is_a? NamedTupleLiteral %}
          headers ||= HTTP::Headers.new
          headers["Content-Type"] = "application/json"
          body = JSON.build do |json|
            json.object do
              {% for key, value in body %}
                json.field {{key.stringify}}, {{value}}
              {% end %}
            end
          end
        {% else %}
          body = {{body}}
        {% end %}

        concurrent = {{concurrent}}
        secure = {{secure}}
      {% end %}

      # Exec the request
      response = transport.http(
        method: {{method.upcase.stringify.id}},
        path: path,
        body: body,
        params: params,
        headers: headers,
        concurrent: concurrent,
        secure: secure,
      )
      unless response.success?
        logger.debug { response.body }
        raise "unexpected response #{response.status_code}\n#{response.body}"
      end
      # Parse the response
      {% verbatim do %}
        {% if model %}
          {{model}}.from_json response.body
        {% else %}
          if response.body.empty?
            JSON::Any.new nil
          else
            JSON.parse response.body
          end
        {% end %}
      {% end %}
    end
  {% end %}

  # Implement the HTTP helpers
  protected def http(method, path, body : ::HTTP::Client::BodyType = nil,
                     params : Hash(String, String?) | URI::Params = URI::Params.new,
                     headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                     secure = false, concurrent = false) : ::HTTP::Client::Response
    transport.http(method, path, body, params, headers, secure, concurrent)
  end

  protected def get(path,
                    params : Hash(String, String?) | URI::Params = URI::Params.new,
                    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                    secure = false, concurrent = false)
    transport.http("GET", path, params: params, headers: headers, secure: secure, concurrent: concurrent)
  end

  protected def post(path, body : ::HTTP::Client::BodyType = nil,
                     params : Hash(String, String?) | URI::Params = URI::Params.new,
                     headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                     secure = false, concurrent = false)
    transport.http("POST", path, body, params, headers, secure, concurrent)
  end

  protected def put(path, body : ::HTTP::Client::BodyType = nil,
                    params : Hash(String, String?) | URI::Params = URI::Params.new,
                    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                    secure = false, concurrent = false)
    transport.http("PUT", path, body, params, headers, secure, concurrent)
  end

  protected def patch(path, body : ::HTTP::Client::BodyType = nil,
                      params : Hash(String, String?) | URI::Params = URI::Params.new,
                      headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                      secure = false, concurrent = false)
    transport.http("PATCH", path, body, params, headers, secure, concurrent)
  end

  protected def delete(path, body : ::HTTP::Client::BodyType = nil,
                       params : Hash(String, String?) | URI::Params = URI::Params.new,
                       headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                       secure = false, concurrent = false)
    transport.http("DELETE", path, body, params, headers, secure, concurrent)
  end

  # Implement transport
  class TransportHTTP < Transport
    # timeouts in seconds
    def initialize(
      @queue : PlaceOS::Driver::Queue,
      @uri : String,
      @settings : ::PlaceOS::Driver::Settings,
      &@received : -> Nil
    )
      @terminated = false
      @uri_base = URI.parse(@uri)
      @ip = @uri_base.hostname.not_nil!
      @http_client_mutex = Mutex.new
      @params_base = @uri_base.query_params

      keep_alive = @settings.get { setting?(UInt32, :http_keep_alive_seconds) } || 20
      @keep_alive = keep_alive.seconds

      max_requests = @settings.get { setting?(Int32, :http_max_requests) } || 1000
      @max_requests = max_requests
      @client_idle = Time.monotonic
      @client_requests = 0

      @tls = __is_https? ? new_tls_context : nil
      @client = new_http_client(@uri_base, @tls)
    end

    @params_base : URI::Params
    @client : ConnectProxy::HTTPClient
    @client_idle : Time::Span
    @keep_alive : Time::Span
    @max_requests : Int32
    @ip : String
    @tls : OpenSSL::SSL::Context::Client?

    property :received

    def connect(connect_timeout : Int32 = 10) : Nil
      return if @terminated

      # Yeild here so this function has the same semantics as a connection
      Fiber.yield

      # Enable queuing
      @queue.online = true
    end

    protected def __is_https?
      (@uri_base.scheme || "http").ends_with?('s')
    end

    protected def __new_http_client
      @client.try(&.close) rescue nil

      # NOTE:: modify in initializer if editing here
      @client = new_http_client(@uri_base, @tls)
      @client_requests = 0
      @client
    end

    protected def with_shared_client(&)
      @http_client_mutex.synchronize do
        now = Time.monotonic
        idle_for = now - @client_idle
        __new_http_client if @client.__place_socket_invalid? || idle_for >= @keep_alive || @client_requests >= @max_requests
        @client_idle = now
        @client_requests += 1

        begin
          yield @client
        rescue IO::Error
          # socket may have been terminated silently so we'll try again
          yield __new_http_client
        ensure
          if @client_requests >= @max_requests
            begin
              @client.close
              @client_requests = Int32::MAX
            rescue
            end
          end
        end
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    def http(method, path, body : ::HTTP::Client::BodyType = nil,
             params : Hash(String, String?) | URI::Params = URI::Params.new,
             headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
             secure = false, concurrent = false) : ::HTTP::Client::Response
      raise "driver terminated" if @terminated

      scheme = @uri_base.scheme || "http"
      host = @uri_base.host

      # Normalise the components
      port = @uri_base.port
      port = port ? ":#{port}" : ""
      base_path = @uri_base.path || ""

      # Grab a base path that we can pair with the passed in path
      base_path = base_path[0..-2] if base_path.ends_with?('/')

      # Build the new URI
      uri = URI.parse("#{scheme}://#{host}#{port}#{base_path}#{path}")

      # Apply any default params
      params = if params.is_a?(Hash)
                 URI::Params.new(params.transform_values { |v| v ? [v] : [] of String })
               else
                 params
               end
      @params_base.each { |key, value| params[key] = value }

      if !params.empty?
        uri.query_params.each { |key, value| params[key] = value }
        uri.query_params = params
      end

      # Apply a default fragment
      if (base_fragment = @uri_base.fragment) && !@uri_base.fragment.try &.empty?
        uri_fragment = uri.fragment
        uri.fragment = base_fragment if uri_fragment.nil? || uri_fragment.empty?
      end

      # Apply headers
      headers = headers.is_a?(Hash) ? HTTP::Headers.new.tap { |head| headers.map { |key, value| head[key] = value } } : headers
      cookies.add_request_headers(headers) unless @settings.get { setting?(Bool, :disable_cookies) } || false

      logger.debug { "http transport requesting: #{method.to_s.upcase} #{uri.request_target}" }

      # Make the request
      response = if concurrent || @max_requests.zero?
                   client = new_http_client(uri, @tls)
                   client.exec(method.to_s.upcase, uri.request_target, headers, body).tap { client.close }
                 else
                   # Only a single request can occur at a time
                   # crystal does not provide any queuing mechanism so this mutex does the trick
                   with_shared_client do |shared_client|
                     resp = shared_client.exec(method.to_s.upcase, uri.request_target, headers, body)
                     if keep_alive = resp.headers["Keep-Alive"]?
                       parse_keep_alive(keep_alive)
                     end
                     resp
                   end
                 end

      # assuming we're typically online, this check before assignment is more performant
      @queue.online = true unless @queue.online
      @received.call

      # fallback in case the HTTP client lib doesn't decompress the response
      check_http_response_encoding response
    rescue error : IO::Error | ArgumentError
      @queue.online = false
      raise error
    end

    private def parse_keep_alive(keep_alive : String) : Nil
      keep_alive.split(',').each do |value|
        parts = value.strip.split('=')
        case parts[0]
        when "timeout"
          @keep_alive = parts[1].to_i.seconds
        when "max"
          @max_requests = parts[1].to_i
        end
      end
    end

    def terminate : Nil
      @terminated = true
    end

    def disconnect : Nil
    end

    def send(message) : TransportHTTP
      raise "not available to HTTP drivers"
    end

    def send(message, task : PlaceOS::Driver::Task, &_block : (Bytes, PlaceOS::Driver::Task) -> Nil) : TransportHTTP
      raise "not available to HTTP drivers"
    end
  end
end
