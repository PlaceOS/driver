require "json"

abstract class PlaceOS::Driver
  module Interface::ChatBot
    # NOTE:: expects messages to broadcast to a channel, such as: chat/<bot_name>/<org_id>/message

    struct Id
      include JSON::Serializable

      # something used to identify the message
      property message_id : String

      # The room ID of the message.
      property room_id : String?

      # The user who sent the message
      property user_id : String?
    end

    struct Message
      include JSON::Serializable

      property id : Id

      # The message, in plain text.
      property text : String
    end

    struct Attachment
      include JSON::Serializable

      property name : String

      # Base64 encoded binary contents
      property payload : String
    end

    abstract def notify_typing(id : Id)

    abstract def reply(id : Id, response : String, url : String? = nil, attachment : Attachment? = nil)
  end
end
