# Common SMS Gateway Interface
module ACAEngine::Driver::Interface; end

module ACAEngine::Driver::Interface::SMS
  abstract def send_sms(
    phone_numbers : String | Array(String),
    message : String,
    # Is it an SMS or MMS
    format : String? = "SMS",
    # Source / originating number
    source : String? = nil
  )
end
