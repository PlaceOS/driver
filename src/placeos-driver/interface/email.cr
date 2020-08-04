# Common Email interface
module PlaceOS::Driver::Interface; end

module PlaceOS::Driver::Interface::Email
  # Where `content` is Base64 encoded.
  alias Attachment = NamedTuple(file_name: String, content: String)
  alias ResourceAttachment = NamedTuple(file_name: String, content: String, content_id: String)

  abstract def send_email(
    subject : String,
    to : String | Array(String),
    from : String | Array(String) | Nil = nil,
    message_html : String = "",
    message_plaintext : String = "",
    attachments : Array(Attachment) = [] of Attachment,
    resource_attachments : Array(ResourceAttachment) = [] of ResourceAttachment,
    cc : String | Array(String) = [] of String,
    bcc : String | Array(String) = [] of String
  )
end
