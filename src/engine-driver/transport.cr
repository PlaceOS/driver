require "tokenizer"
require "./transport/http_proxy"

abstract class EngineDriver::Transport
  abstract def send(message) : EngineDriver::Transport
  abstract def send(message, task : EngineDriver::Task, &block : (Bytes, EngineDriver::Task) -> Nil) : EngineDriver::Transport
  abstract def terminate : Nil
  abstract def disconnect : Nil
  abstract def start_tls(verify_mode : OpenSSL::SSL::VerifyMode, context : OpenSSL::SSL::Context) : Nil
  abstract def connect(connect_timeout : Int32) : Nil

  @tokenizer : ::Tokenizer? = nil
  property tokenizer : ::Tokenizer?

  # Only SSH implements exec
  def exec(message) : SSH2::Channel
    raise ::IO::EOFError.new("exec is only available to SSH transports")
  end

  # Many devices have a HTTP service. Might as well make it easy to access.
  macro inherited
    def http(method, path, body : ::HTTP::Client::BodyType = nil,
      params : Hash(String, String?) = {} of String => String?,
      headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
      secure = false, concurrent = true
    ) : ::HTTP::Client::Response
      {% if @type.name.stringify == "EngineDriver::TransportLogic" %}
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

    {% if @type.name.stringify != "EngineDriver::TransportLogic" %}
      protected def new_http_client(uri, context)
        client = HTTPClient.new(uri, context)

        # Ensure client socket has not been closed
        client.before_request { client.check_socket_valid }

        # Apply basic auth settings
        if auth = @settings.get { setting?(NamedTuple(username: String, password: String), :basic_auth) }
          client.basic_auth **auth
        end

        # Apply proxy settings
        if proxy_config = @settings.get { setting?(NamedTuple(host: String, port: Int32, auth: NamedTuple(username: String, password: String)?), :proxy) }
          proxy = HTTPProxy.new(**proxy_config)
          client.before_request { client.set_proxy(proxy) }
        end

        client
      end
    {% end %}

    def enable_multicast_loop(state = true)
      {% if @type.name.stringify == "EngineDriver::TransportUDP" %}
        @socket.try &.multicast_loopback = state
      {% end %}
      state
    end
  end

  protected def process(data) : Nil
    if tokenize = @tokenizer
      messages = tokenize.extract(data)
      if messages.size == 1
        process_message(messages[0])
      else
        messages.each { |message| spawn { process_message(message) } }
      end
    else
      process_message(data)
    end
  end

  private def process_message(data)
    # Check if the task provided a response processing block
    if task = @queue.current
      if processing = task.processing
        processing.call(data, task)
        return
      end
    end

    # See spec for how this callback is expected to be used
    @received.call(data, @queue.current)
  rescue error
    @logger.error "error processing received data\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
  end
end
