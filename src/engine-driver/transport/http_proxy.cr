require "connect-proxy"

class ConnectProxy::HTTPClient
  # Allows the connection to be re-established
  def check_socket_valid
    socket = @socket
    @socket = nil if socket && socket.closed?
  end
end
