module PlaceOS::Driver::Utilities::WakeOnLAN
  @@udp_server_v4 : UDPSocket?
  @@udp_server_v6 : UDPSocket?

  def self.upd_v4
    udp = @@udp_server_v4
    return udp if udp
    @@udp_server_v4 = udp = UDPSocket.new Socket::Family::INET
    udp.broadcast = true

    # allow for a custom port to be defined
    udp.bind "0.0.0.0", ENV["PLACEOS_WOL_PORT"]?.try(&.to_i) || 0
    udp
  end

  def self.upd_v6
    udp = @@udp_server_v6
    return udp if udp
    @@udp_server_v6 = udp = UDPSocket.new Socket::Family::INET6
    # iNet6 doesn't have broadcast - destination address should be FF02::1
    # https://msdn.microsoft.com/en-us/library/ff361877.aspx

    # allow for a custom port to be defined
    udp.bind "::", ENV["PLACEOS_WOL_PORT"]?.try(&.to_i) || 0
    udp
  end

  def self.wake_device(mac_address, subnet = "255.255.255.255", port = 9, address : Socket::Address? = nil)
    address = address || Socket::Address.parse("ip://#{subnet}:#{port}/")
    udp = case address.family
          when Socket::Family::INET6
            upd_v6
          when Socket::Family::INET
            upd_v4
          else
            raise "Unsupported subnet type: #{address.family} (#{address.family.value})"
          end

    mac_address = mac_address.gsub(/(0x|[^0-9A-Fa-f])*/, "").scan(/.{2}/).map(&.[0]).join("")
    magicpacket = "ff" * 6 + mac_address * 16

    # The send methods may sporadically fail with Errno::ECONNREFUSED when sending datagrams to a non-listening server
    # https://crystal-lang.org/api/0.27.0/UDPSocket.html
    begin
      udp.send(magicpacket.hexbytes, address)
    rescue ex : Socket::ConnectError
    end
  end
end
