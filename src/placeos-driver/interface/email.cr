# Common Email interface
module PlaceOS::Driver::Interface; end

module PlaceOS::Driver::Interface::Email
  # Where `content` is Base64 encoded.
  alias Attachment = NamedTuple(file_name: String, content: String)
  alias ResourceAttachment = NamedTuple(file_name: String, content: String, content_id: String)

  abstract def send_email(
    to : Array(String),
    subject : String,
    message_html : String = nil,
    message_plaintext : String = nil,
    attachments : Array(Attachment)? = nil,
    resource_attachments : Array(ResourceAttachment)? = nil,
    cc : Array(String)? = nil,
    bcc : Array(String)? = nil
  )
end
