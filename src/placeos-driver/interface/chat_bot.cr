require "json"

abstract class PlaceOS::Driver
  # NOTE:: expects messages to broadcast to a channel, such as: chat/<bot_name>/<org_id>/message
  module Interface::ChatBot
    struct Id
      include JSON::Serializable

      def initialize(@message_id, @room_id = nil, @user_id = nil, @org_id = nil)
      end

      # something used to identify the message
      property message_id : String

      # The room ID of the message.
      property room_id : String?

      # The user who sent the message
      property user_id : String?

      # The org sending the message.
      property org_id : String?
    end

    struct Message
      include JSON::Serializable

      def initialize(@id, @text)
      end

      property id : Id

      # The message, in plain text.
      property text : String
    end

    struct Attachment
      include JSON::Serializable

      def initialize(@name, @payload)
      end

      property name : String

      # Base64 encoded binary contents
      property payload : String
    end

    # allows a bot responder to indicate it is replying to a message
    abstract def notify_typing(id : Id)

    # interface used to reply to a message
    abstract def reply(id : Id, response : String, url : String? = nil, attachment : Attachment? = nil)
  end
end
