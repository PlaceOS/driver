require "http"
require "./http_proxy"

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
    private macro {{method.id}}_request(path, params = {} of String => String?, headers = HTTP::Headers.new, body = nil, secure = false, concurrent = false, as model = nil)
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
                     params : Hash(String, String?) = {} of String => String?,
                     headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                     secure = false, concurrent = false) : ::HTTP::Client::Response
    transport.http(method, path, body, params, headers, secure, concurrent)
  end

  protected def get(path,
                    params : Hash(String, String?) = {} of String => String?,
                    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                    secure = false, concurrent = false)
    transport.http("GET", path, params: params, headers: headers, secure: secure, concurrent: concurrent)
  end

  protected def post(path, body : ::HTTP::Client::BodyType = nil,
                     params : Hash(String, String?) = {} of String => String?,
                     headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                     secure = false, concurrent = false)
    transport.http("POST", path, body, params, headers, secure, concurrent)
  end

  protected def put(path, body : ::HTTP::Client::BodyType = nil,
                    params : Hash(String, String?) = {} of String => String?,
                    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                    secure = false, concurrent = false)
    transport.http("PUT", path, body, params, headers, secure, concurrent)
  end

  protected def patch(path, body : ::HTTP::Client::BodyType = nil,
                      params : Hash(String, String?) = {} of String => String?,
                      headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                      secure = false, concurrent = false)
    transport.http("PATCH", path, body, params, headers, secure, concurrent)
  end

  protected def delete(path,
                       params : Hash(String, String?) = {} of String => String?,
                       headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                       secure = false, concurrent = false)
    transport.http("DELETE", path, params: params, headers: headers, secure: secure, concurrent: concurrent)
  end

  # Implement transport
  class TransportHTTP < Transport
    # timeouts in seconds
    def initialize(@queue : PlaceOS::Driver::Queue, uri_base : String, @settings : ::PlaceOS::Driver::Settings)
      @terminated = false
      @logger = @queue.logger
      @tls = new_tls_context
      @uri_base = URI.parse(uri_base)
      @http_client_mutex = Mutex.new

      base_query = @uri_base.query

      @params_base = {} of String => String?
      if base_query && !base_query.empty?
        base_query.split('&').map(&.split('=')).each { |part| @params_base[part[0]] = part[1]? }
      end

      context = uri_base.starts_with?("https") ? @tls : nil
      @client = new_http_client(@uri_base, context)
    end

    @params_base : Hash(String, String?)
    @logger : ::Logger
    @tls : OpenSSL::SSL::Context::Client
    @client : HTTP::Client

    property :received
    getter :logger

    def connect(connect_timeout : Int32 = 10) : Nil
      return if @terminated

      # Yeild here so this function has the same semantics as a connection
      Fiber.yield

      # Enable queuing
      @queue.online = true
    end

    def start_tls(verify_mode = OpenSSL::SSL::VerifyMode::NONE, context = @tls) : Nil
      tls = context || OpenSSL::SSL::Context::Client.new
      tls.verify_mode = verify_mode
      @tls = tls

      # Re-create the client with the new TLS configuration
      @client = new_http_client(@uri_base, @tls)
    end

    protected def with_shared_client
      @http_client_mutex.synchronize do
        yield @client
      end
    end

    def http(method, path, body : ::HTTP::Client::BodyType = nil,
             params : Hash(String, String?) = {} of String => String?,
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
      base_path = base_path[0..-2] if scheme.ends_with?('/')

      # Build the new URI
      uri = URI.parse("#{scheme}://#{host}#{port}#{base_path}#{path}")

      # Apply any default params
      params = @params_base.merge(params)
      if !params.empty?
        if (query = uri.query) && !uri.query.try &.empty?
          # merge
          query.split('&').map(&.split('=')).each { |part| params[part[0]] = part[1]? }
        end

        uri.query = params.map { |key, value| value ? "#{key}=#{value}" : key }.join("&")
      end

      # Apply a default fragment
      if (base_fragment = @uri_base.fragment) && !@uri_base.fragment.try &.empty?
        uri_fragment = uri.fragment
        uri.fragment = base_fragment if uri_fragment.nil? || uri_fragment.empty?
      end

      # Apply headers
      headers = headers.is_a?(Hash) ? HTTP::Headers.new.tap { |head| headers.map { |key, value| head[key] = value } } : headers

      # Make the request
      if concurrent
        # Does this request require a TLS context?
        context = (scheme.try &.ends_with?('s')) ? new_tls_context : nil
        client = new_http_client(uri, context)
        client.exec(method.to_s.upcase, uri.full_path, headers, body)
      else
        # Only a single request can occur at a time
        # crystal does not provide any queuing mechanism so this mutex does the trick
        with_shared_client do |client|
          client.exec(method.to_s.upcase, uri.full_path, headers, body)
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

    def send(message, task : PlaceOS::Driver::Task, &block : (Bytes, PlaceOS::Driver::Task) -> Nil) : TransportHTTP
      raise "not available to HTTP drivers"
    end
  end
end
