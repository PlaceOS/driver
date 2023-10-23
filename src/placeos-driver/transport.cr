require "tokenizer"
require "./transport/http_proxy"

abstract class PlaceOS::Driver::Transport
  abstract def send(message) : PlaceOS::Driver::Transport
  abstract def send(message, task : PlaceOS::Driver::Task, &_block : (Bytes, PlaceOS::Driver::Task) -> Nil) : PlaceOS::Driver::Transport
  abstract def terminate : Nil
  abstract def disconnect : Nil
  abstract def start_tls(verify_mode : OpenSSL::SSL::VerifyMode, context : OpenSSL::SSL::Context) : Nil
  abstract def connect(connect_timeout : Int32) : Nil

  property tokenizer : ::Tokenizer? = nil
  property pre_processor : ((Bytes) -> Bytes?) | Nil = nil
  getter proxy_in_use : String? = nil
  getter cookies : ::HTTP::Cookies { ::HTTP::Cookies.new }

  # for non-http drivers to define a non-default http endpoint
  property http_uri_override : URI? = nil

  def pre_processor(&@pre_processor : (Bytes) -> Bytes?)
  end

  def before_request(&@before_request : HTTP::Request ->)
  end

  # Only SSH implements exec
  def exec(message) : SSH2::Channel
    raise ::IO::EOFError.new("exec is only available to SSH transports")
  end

  # Use `logger` of `Driver::Queue`
  delegate logger, to: @queue

  macro __build_http_helper__
    {% if @type.name.stringify != "PlaceOS::Driver::TransportHTTP" %}
      def http(method, path, body : ::HTTP::Client::BodyType = nil,
        params : Hash(String, String?) | URI::Params = URI::Params.new,
        headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
        secure = false, concurrent = true
      ) : ::HTTP::Client::Response
        {% if @type.name.stringify == "PlaceOS::Driver::TransportLogic" %}
          raise "HTTP requests are not available in logic drivers"
        {% else %}

          if uri_override = http_uri_override
            uri = uri_override
          elsif (uri_config = @uri.try(&.strip)) && !uri_config.empty?
            uri = URI.parse uri_config
          end

          if uri
            context = case uri.scheme
                      when "https", "wss"
                        uri.scheme = "https"
                        OpenSSL::SSL::Context::Client.new.tap &.verify_mode = OpenSSL::SSL::VerifyMode::NONE
                      when "ws"
                        uri.scheme = "http"
                        nil
                      else
                        nil
                      end
          else
            context = if secure
                        uri = URI.parse "https://#{@ip}"

                        if secure.is_a?(OpenSSL::SSL::Context::Client)
                          secure
                        else
                          OpenSSL::SSL::Context::Client.new.tap &.verify_mode = OpenSSL::SSL::VerifyMode::NONE
                        end
                      else
                        uri = URI.parse "http://#{@ip}"
                        nil
                      end
          end

          # Build the new URI
          uri.path = path
          params = if params.is_a?(Hash)
                    URI::Params.new(params.transform_values { |v| v ? [v] : [] of String })
                  else
                    params
                  end
          uri.query_params = params

          # Apply headers
          headers = headers.is_a?(Hash) ? HTTP::Headers.new.tap { |head| headers.map { |key, value| head[key] = value } } : headers

          # Make the request
          client = new_http_client(uri, context)
          cookies.add_request_headers(headers) unless @settings.get { setting?(Bool, :disable_cookies) } || false
          logger.debug { "http helper requesting: #{method.to_s.upcase} #{uri.request_target}" }
          check_http_response_encoding client.exec(method.to_s.upcase, uri.request_target, headers, body).tap { client.close }
        {% end %}
      end
    {% end %}

    protected def check_http_response_encoding(response)
      headers = response.headers
      cookies.fill_from_server_headers(headers) unless @settings.get { setting?(Bool, :disable_cookies) } || false
      encoding = headers["Content-Encoding"]?
      if encoding.in?({"gzip", "deflate"})
        response.consume_body_io
        body = response.body

        if !body.blank?
          body_io = IO::Memory.new(body)
          body = case encoding
                 when "gzip"
                   Compress::Gzip::Reader.open(body_io, &.gets_to_end)
                 when "deflate"
                   Compress::Deflate::Reader.open(body_io, &.gets_to_end)
                 end

          headers.delete("Content-Encoding")
          headers.delete("Content-Length")

          response = HTTP::Client::Response.new(response.status, body, headers, response.status_message, response.version)
        end
      end
      response
    end

    {% if @type.name.stringify != "PlaceOS::Driver::TransportLogic" %}
      protected def new_http_client(uri, context)
        client = ConnectProxy::HTTPClient.new(uri, context, ignore_env: true)
        connect_timeout = (@settings.get { setting?(Int32, :http_connect_timeout) } || 10).seconds
        comms_timeout = (@settings.get { setting?(Int32, :http_comms_timeout) } || 120).seconds
        client.dns_timeout = connect_timeout
        client.connect_timeout = connect_timeout
        client.read_timeout = comms_timeout
        client.write_timeout = comms_timeout

        # Apply basic auth settings
        if auth = @settings.get { setting?(NamedTuple(username: String, password: String), :basic_auth) }
          client.basic_auth **auth
        end

        # Apply proxy settings
        if proxy_config = @settings.get { setting?(NamedTuple(host: String, port: Int32, auth: NamedTuple(username: String, password: String)?), :proxy) }
          # this check is here so we can disable proxies as required
          if proxy_config[:host].presence
            proxy = ConnectProxy.new(**proxy_config)
            client.before_request { client.set_proxy(proxy.not_nil!) }
          end
        elsif ConnectProxy.behind_proxy?
          # Apply environment defined proxy
          begin
            proxy = ConnectProxy.new(*ConnectProxy.parse_proxy_url)
            client.before_request { client.set_proxy(proxy.not_nil!) }
          rescue error
            logger.warn(exception: error) { "failed to apply environment proxy URI" }
          end
        end

        @proxy_in_use = proxy.try &.proxy_host

        # Check if we need to override the Host header
        if host_header = @settings.get { setting?(String, :host_header) }
          client.before_request { |request| request.headers["Host"] = host_header }
        end

        client.compress = true
        if before_req = @before_request
          client.before_request &before_req
        end
        client
      end
    {% end %}

    def enable_multicast_loop(state = true)
      {% if @type.name.stringify == "PlaceOS::Driver::TransportUDP" %}
        @socket.try &.multicast_loopback = state
      {% end %}
      state
    end
  end

  # Many devices have a HTTP service. Might as well make it easy to access.
  macro inherited
    __build_http_helper__
  end

  protected def new_tls_context(verify_mode : OpenSSL::SSL::VerifyMode? = nil) : OpenSSL::SSL::Context::Client
    use_insecure_cipher = @settings.get { setting?(Bool, :https_insecure) }
    tls = use_insecure_cipher ? OpenSSL::SSL::Context::Client.insecure : OpenSSL::SSL::Context::Client.new
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
        Log.warn(exception: error) { "issue configuring verify mode" }
        tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      end
    end
    tls
  end

  private def process(data : Bytes) : Nil
    if pre = @pre_processor
      tmp_data = pre.call(data)
      return unless tmp_data
      return if tmp_data.empty?
      data = tmp_data
    end

    if tokenize = @tokenizer
      messages = tokenize.extract(data)
      messages.each do |message|
        spawn(same_thread: true) { process_message(message) }
        Fiber.yield
      end
    else
      spawn(same_thread: true) { process_message(data) }
      Fiber.yield
    end
  rescue error
    Log.error(exception: error) { "error processing data" }

    # if there was an error here, we don't really want to be buffering anything
    @tokenizer.try &.clear
  end

  private def process_message(data)
    # We want to ignore completed tasks as they could not have been the cause of the data
    # The next task has not executed so this data is not associated with a task
    task = @queue.current
    task = nil if task.try &.complete?

    # Check if the task provided a response processing block
    if task
      if processing = task.processing
        processing.call(data, task)
        return
      end
    end

    # See spec for how this callback is expected to be used
    @received.call(data, task)
  rescue error
    Log.error(exception: error) { "error processing received data" }
  end
end
