require "tokenizer"
require "./transport/http_proxy"

abstract class PlaceOS::Driver::Transport
  abstract def send(message) : PlaceOS::Driver::Transport
  abstract def send(message, task : PlaceOS::Driver::Task, &block : (Bytes, PlaceOS::Driver::Task) -> Nil) : PlaceOS::Driver::Transport
  abstract def terminate : Nil
  abstract def disconnect : Nil
  abstract def start_tls(verify_mode : OpenSSL::SSL::VerifyMode, context : OpenSSL::SSL::Context) : Nil
  abstract def connect(connect_timeout : Int32) : Nil

  property tokenizer : ::Tokenizer? = nil

  # Only SSH implements exec
  def exec(message) : SSH2::Channel
    raise ::IO::EOFError.new("exec is only available to SSH transports")
  end

  # Use `logger` of `Driver::Queue`
  delegate logger, to: @queue

  # Many devices have a HTTP service. Might as well make it easy to access.
  macro inherited
    def http(method, path, body : ::HTTP::Client::BodyType = nil,
      params : Hash(String, String?) = {} of String => String?,
      headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
      secure = false, concurrent = true
    ) : ::HTTP::Client::Response
      {% if @type.name.stringify == "PlaceOS::Driver::TransportLogic" %}
        raise "HTTP requests are not available in logic drivers"
      {% else %}
        uri_config = @uri.try(&.strip)
        if uri_config && !uri_config.empty?
          base_path = uri_config
          context = if base_path.starts_with?("https")
                      OpenSSL::SSL::Context::Client.new.tap &.verify_mode = OpenSSL::SSL::VerifyMode::NONE
                    else
                      nil
                    end
        else
          context = if secure
                      base_path = "https://#{@ip}"

                      if secure.is_a?(OpenSSL::SSL::Context::Client)
                        secure
                      else
                        OpenSSL::SSL::Context::Client.new.tap &.verify_mode = OpenSSL::SSL::VerifyMode::NONE
                      end
                    else
                      base_path = "http://#{@ip}"
                      nil
                    end
        end

        # Build the new URI
        uri = URI.parse("#{base_path}#{path}")
        uri.query = params.map { |key, value| value ? "#{key}=#{value}" : key }.join("&") unless params.empty?

        # Apply headers
        headers = headers.is_a?(Hash) ? HTTP::Headers.new.tap { |head| headers.map { |key, value| head[key] = value } } : headers

        # Make the request
        client = new_http_client(uri, context)
        client.exec(method.to_s.upcase, uri.full_path, headers, body)
      {% end %}
    end

    {% if @type.name.stringify != "PlaceOS::Driver::TransportLogic" %}
      protected def new_http_client(uri, context)
        client = ConnectProxy::HTTPClient.new(uri, context)

        # Ensure client socket has not been closed
        client.before_request { client.check_socket_valid }

        # Apply basic auth settings
        if auth = @settings.get { setting?(NamedTuple(username: String, password: String), :basic_auth) }
          client.basic_auth **auth
        end

        # Apply proxy settings
        if proxy_config = @settings.get { setting?(NamedTuple(host: String, port: Int32, auth: NamedTuple(username: String, password: String)?), :proxy) }
          proxy = ConnectProxy.new(**proxy_config)
          client.before_request { client.set_proxy(proxy) }
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

  protected def new_tls_context(verify_mode : OpenSSL::SSL::VerifyMode? = nil) : OpenSSL::SSL::Context::Client
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
        Log.warn(exception: error) { "issue configuring verify mode" }
        tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      end
    end
    tls
  end

  private def process(data : Bytes) : Nil
    if tokenize = @tokenizer
      messages = tokenize.extract(data)
      if messages.size == 1
        process_message(messages[0])
      else
        messages.each { |message| process_message(message) }
      end
    else
      process_message(data)
    end
  rescue error
    Log.error(exception: error) { "error processing data" }
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
