# Common SMS Gateway Interface
module EngineDriver::Interface; end

module EngineDriver::Interface::SMS
  abstract def send_sms(
    phone_numbers : String | Array(String),
    message : String,
    # Is it an SMS or MMS
    format : String? = "SMS",
    # Source / originating number
    source : String? = nil
  )
end
