# Common Email interface
module PlaceOS::Driver::Interface; end

module PlaceOS::Driver::Interface::Mailer
  # Where `content` is Base64 encoded.
  alias Attachment = NamedTuple(file_name: String, content: String)
  alias ResourceAttachment = NamedTuple(file_name: String, content: String, content_id: String)

  abstract def send_email(
    to : String | Array(String),
    subject : String,
    message_plaintext : String? = nil,
    message_html : String? = nil,
    resource_attachments : Array(ResourceAttachment) = [] of ResourceAttachment,
    attachments : Array(Attachment) = [] of Attachment,
    cc : String | Array(String) = [] of String,
    bcc : String | Array(String) = [] of String,
    from : String | Array(String) | Nil = nil
  )
end
