require "connect-proxy"

# maintain basic backwards compatibility
{% if compare_versions(Crystal::VERSION, "0.36.0") < 0 %}
  require "uri"

  class URI
    def request_target
      full_path
    end
  end
{% end %}

class ConnectProxy::HTTPClient
  # Allows the connection to be re-established
  def __place_socket_invalid?
    socket = {% if compare_versions(Crystal::VERSION, "0.36.0") < 0 %} @socket {% else %} @io {% end %}
    socket && socket.closed?
  end
end
