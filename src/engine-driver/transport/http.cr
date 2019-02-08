require "http"

class EngineDriver
  # Implement the HTTP helpers
  protected def http(method, path, body : HTTP::Client::BodyType = nil,
    params : Hash(String, String?) = {} of String => String?,
    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
    secure = false
  ) : HTTP::Client::Response
    transport.http(method, path, body, params, headers, secure)
  end

  protected def get(path,
    params : Hash(String, String?) = {} of String => String?,
    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
    secure = false
  )
    transport.http("GET", path, params: params, headers: headers, secure: secure)
  end

  protected def post(path, body : HTTP::Client::BodyType = nil,
    params : Hash(String, String?) = {} of String => String?,
    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
    secure = false
  )
    transport.http("POST", path, body, params, headers, secure)
  end

  protected def put(path, body : HTTP::Client::BodyType = nil,
    params : Hash(String, String?) = {} of String => String?,
    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
    secure = false
  )
    transport.http("PUT", path, body, params, headers, secure)
  end

  protected def patch(path, body : HTTP::Client::BodyType = nil,
    params : Hash(String, String?) = {} of String => String?,
    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
    secure = false
  )
    transport.http("PATCH", path, body, params, headers, secure)
  end

  protected def delete(path,
    params : Hash(String, String?) = {} of String => String?,
    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
    secure = false
  )
    transport.http("DELETE", path, params: params, headers: headers, secure: secure)
  end

  # Implement transport
  class TransportHTTP < Transport
    # timeouts in seconds
    def initialize(@queue : EngineDriver::Queue, uri_base : String, @settings : ::EngineDriver::Settings)
      @terminated = false
      @logger = @queue.logger
      @tls = OpenSSL::SSL::Context::Client.new
      @uri_base = URI.parse(uri_base)

      base_query = @uri_base.query

      @params_base = {} of String => String?
      if base_query && !base_query.empty?
        base_query.split('&').map(&.split('=')).each { |part| @params_base[part[0]] = part[1]? }
      end

      begin
        if mode = @settings.get { setting?(Int32, :https_verify) }
          # TODO:: use strings and parse here crystal-lang/crystal#7382
          # @tls.verify_mode = OpenSSL::SSL::VerifyMode.parse(mode)
          @tls.verify_mode = OpenSSL::SSL::VerifyMode.from_value(mode)
        else
          @tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
        end
      rescue error
        @logger.warn "issue configuring verify mode\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
        @tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      end
    end

    @params_base : Hash(String, String?)
    @logger : ::Logger
    property :received
    getter :logger

    def connect(connect_timeout : Int32 = 10)
      return if @terminated

      # Enable queuing
      spawn { @queue.online = true }
    end

    def start_tls(verify_mode = OpenSSL::SSL::VerifyMode::NONE, context = @tls)
      tls = context || OpenSSL::SSL::Context::Client.new
      tls.verify_mode = verify_mode
      @tls = tls
      true
    end

    def http(method, path, body : HTTP::Client::BodyType = nil,
      params : Hash(String, String?) = {} of String => String?,
      headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
      secure = false
    ) : HTTP::Client::Response
      raise "driver terminated" if @terminated

      scheme = @uri_base.scheme || "http"
      host = @uri_base.host

      # Normalise the components
      port = @uri_base.port
      port = port ? ":#{port}" : ""
      base_path = @uri_base.path || ""

      # Does this request require a TLS context?
      context = (scheme.try &.ends_with?('s')) ? @tls : nil

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
      HTTP::Client.exec(method.to_s.upcase, uri, headers, body, tls: context)
    end

    def terminate
      @terminated = true
    end

    def disconnect
    end

    def send(message) : Int32
      0
    end

    def send(message, task : EngineDriver::Task, &block : Bytes -> Nil) : Int32
      0
    end
  end
end
