module PlaceOS::Driver::Utilities::Transcoder
  # Converts a hex encoded string into bytes
  def hex_to_bytes(string)
    string = string.gsub(/(0x|[^0-9A-Fa-f])*/, "")
    string = "0#{string}" if string.size % 2 > 0
    string.hexbytes
  end

  # Converts a byte array into bytes
  def array_to_bytes(array)
    bytes = Bytes.new(array.size)
    array.each_with_index do |byte, index|
      bytes[index] = 0_u8 | byte
    end
    bytes
  end
end
