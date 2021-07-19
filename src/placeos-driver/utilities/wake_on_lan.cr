module PlaceOS::Driver::Utilities::WakeOnLAN
  def self.udp_v4 : UDPSocket?
    udp_server_v4
  end

  def self.udp_v6 : UDPSocket?
    udp_server_v6
  end

  protected class_getter udp_server_v4 : UDPSocket? do
    UDPSocket.new(Socket::Family::INET).tap do |udp|
      udp.broadcast = true
      # allow for a custom port to be defined
      udp.bind "0.0.0.0", ENV["PLACEOS_WOL_PORT"]?.try(&.to_i) || 0
    end
  end

  protected class_getter udp_server_v6 : UDPSocket? do
    UDPSocket.new(Socket::Family::INET6).tap do |udp|
      # iNet6 doesn't have broadcast - destination address should be FF02::1
      # https://msdn.microsoft.com/en-us/library/ff361877.aspx
      # Allow for a custom port to be defined
      udp.bind "::", ENV["PLACEOS_WOL_PORT"]?.try(&.to_i) || 0
    end
  end

  def self.wake_device(mac_address, subnet = "255.255.255.255", port = 9, address : Socket::Address? = nil)
    address = address || Socket::Address.parse("ip://#{subnet}:#{port}/")
    udp = case address.family
          when .inet6? then udp_v6
          when .inet?  then udp_v4
          else
            raise "Unsupported subnet type: #{address.family} (#{address.family.value})"
          end

    mac_address = mac_address.gsub(/(0x|[^0-9A-Fa-f])*/, "").scan(/.{2}/).join("", &.[0])
    magicpacket = "ff" * 6 + mac_address * 16

    # The send methods may sporadically fail with Errno::ECONNREFUSED when sending datagrams to a non-listening server
    # https://crystal-lang.org/api/0.27.0/UDPSocket.html
    begin
      udp.send(magicpacket.hexbytes, address)
    rescue ex : Socket::ConnectError
    end
  end
end
