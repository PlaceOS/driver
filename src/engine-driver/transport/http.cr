require "http"
require "./http_proxy"

class EngineDriver
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
    def initialize(@queue : EngineDriver::Queue, uri_base : String, @settings : ::EngineDriver::Settings)
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

    def connect(connect_timeout : Int32 = 10)
      return if @terminated

      # Yeild here so this function has the same semantics as a connection
      Fiber.yield

      # Enable queuing
      @queue.online = true
    end

    def start_tls(verify_mode = OpenSSL::SSL::VerifyMode::NONE, context = @tls)
      tls = context || OpenSSL::SSL::Context::Client.new
      tls.verify_mode = verify_mode
      @tls = tls

      # Re-create the client with the new TLS configuration
      @client = new_http_client(@uri_base, @tls)
      true
    end

    def new_tls_context(verify_mode : OpenSSL::SSL::VerifyMode? = nil) : OpenSSL::SSL::Context::Client
      tls = OpenSSL::SSL::Context::Client.new
      if verify_mode
        tls.verify_mode = verify_mode
      else
        begin
          if mode = @settings.get { setting?(String | Int32, :https_verify) }
            # NOTE:: why we use case here crystal-lang/crystal#7382
            if mode.is_a?(String)
              tls.verify_mode = case mode.camelcase.downcase
                                when "none"
                                  OpenSSL::SSL::VerifyMode::NONE
                                when "peer"
                                  OpenSSL::SSL::VerifyMode::PEER
                                when "failifnopeercert"
                                  OpenSSL::SSL::VerifyMode::FAIL_IF_NO_PEER_CERT
                                when "clientonce"
                                  OpenSSL::SSL::VerifyMode::CLIENT_ONCE
                                when "all"
                                  OpenSSL::SSL::VerifyMode::All
                                else
                                  OpenSSL::SSL::VerifyMode::NONE
                                end
            else
              tls.verify_mode = OpenSSL::SSL::VerifyMode.from_value(mode)
            end
          else
            tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
          end
        rescue error
          @logger.warn "issue configuring verify mode\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
          tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
        end
      end
      tls
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

    def terminate
      @terminated = true
    end

    def disconnect
    end

    def send(message)
      raise "not available to HTTP drivers"
    end

    def send(message, task : EngineDriver::Task, &block : (Bytes, EngineDriver::Task) -> Nil)
      raise "not available to HTTP drivers"
    end
  end
end
