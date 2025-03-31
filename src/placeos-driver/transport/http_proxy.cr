require "connect-proxy"

class ConnectProxy::HTTPClient
  # Allows the connection to be re-established
  def __place_socket_invalid?
    socket = @io
    socket && socket.closed?
  end
end
