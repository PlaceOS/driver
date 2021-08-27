abstract class PlaceOS::Driver
  # Common SMS Gateway Interface
  module Interface::SMS
    abstract def send_sms(
      phone_numbers : String | Array(String),
      message : String,
      # Is it an SMS or MMS
      format : String? = "SMS",
      # Source / originating number
      source : String? = nil
    )
  end
end
