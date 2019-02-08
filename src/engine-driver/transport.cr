abstract class EngineDriver::Transport
  abstract def send(message) : Int32
  abstract def send(message, task : EngineDriver::Task, &block : Bytes -> Nil) : Int32
  abstract def terminate : Nil
  abstract def disconnect : Nil
  abstract def start_tls(verify_mode : OpenSSL::SSL::VerifyMode, context : OpenSSL::SSL::Context) : Nil
  abstract def connect(connect_timeout : Int32)

  # Most devices have a HTTP service. Might as well make it easy to access.
  macro inherited
    def http(method, path, body : HTTP::Client::BodyType = nil,
      params : Hash(String, String?) = {} of String => String?,
      headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
      secure = false
    ) : HTTP::Client::Response
      {% if @type.name.stringify == "EngineDriver::TransportLogic" %}
        raise "HTTP requests are not possible against logic drivers"
      {% else %}
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

        # Build the new URI
        uri = URI.parse("#{base_path}#{path}")
        uri.query = params.map { |key, value| value ? "#{key}=#{value}" : key }.join("&") unless params.empty?

        # Apply headers
        headers = headers.is_a?(Hash) ? HTTP::Headers.new.tap { |head| headers.map { |key, value| head[key] = value } } : headers

        # Make the request
        HTTP::Client.exec(method.to_s.upcase, uri, headers, body, tls: context)
      {% end %}
    end
  end

  protected def process(data) : Nil
    # Check if the task provided a response processing block
    if task = @queue.current
      if processing = task.processing
        processing.call(data)
        return
      end
    end

    # See spec for how this callback is expected to be used
    @received.call(data, @queue.current)
  rescue error
    @logger.error "error processing received data\n#{error.message}\n#{error.backtrace?.try &.join("\n")}"
  end
end
