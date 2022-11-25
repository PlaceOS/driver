abstract class PlaceOS::Driver
  module Interface::ChatBot
    # drivers are expected to emit door state events on
    # channel security/event/door
    class Message
      include JSON::Serializable

      # The room ID of the message.
      @[JSON::Field(key: "roomId")]
      property room_id : String

      # The message, in plain text.
      @[JSON::Field(key: "text")]
      property text : String
    end
  end
end
