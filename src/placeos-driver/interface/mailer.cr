abstract class PlaceOS::Driver; end

# Common Email interface
module PlaceOS::Driver::Interface; end

module PlaceOS::Driver::Interface::Mailer
  # Where `content` is Base64 encoded.
  alias Attachment = NamedTuple(file_name: String, content: String)
  alias ResourceAttachment = NamedTuple(file_name: String, content: String, content_id: String)

  abstract def send_mail(
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

  #                   event_name => notify_who => html => template
  alias Templates = Hash(String, Hash(String, Hash(String, String)))
  @templates : Templates = Templates.new

  alias TemplateItems = Hash(String, String | Int64 | Float64 | Bool | Nil)

  def send_template(
    to : String | Array(String),
    template : Tuple(String, String),
    args : TemplateItems,
    resource_attachments : Array(ResourceAttachment) = [] of ResourceAttachment,
    attachments : Array(Attachment) = [] of Attachment,
    cc : String | Array(String) = [] of String,
    bcc : String | Array(String) = [] of String,
    from : String | Array(String) | Nil = nil
  )
    template = begin
      @templates[template[0]][template[1]]
    rescue
      logger.warn { "no template found with: #{template}" }
      return
    end

    subject = build_template(template["subject"], args)
    text = build_template(template["text"]?, args)
    html = build_template(template["html"]?, args)

    send_mail(to, subject, text || "", html || "", resource_attachments, attachments, cc, bcc, from)
  end

  def build_template(string : String?, args : TemplateItems)
    args.each { |key, value| string = string.gsub("%{#{key}}", value) } if string
    string
  end
end
