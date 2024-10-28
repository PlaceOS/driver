require "json"

abstract class PlaceOS::Driver; end

# The namespace for all PlaceOS standard interfaces
module PlaceOS::Driver::Interface; end

# Common Email templates interface
module PlaceOS::Driver::Interface::MailerTemplates
  # Tuple(String, String) is the same as is being used for #send_template
  # example: {"bookings", "booked_by_notify"}
  #
  # example implementation for multiple templates with shared fields:
  #
  # def template_fields : Hash(Tuple(String, String), TemplateFields)
  #   common_fields = [
  #     {name: "booking_id", description: "The ID of the booking"},
  #   ]

  #   {
  #     {"bookings", "booked_by_notify"} => TemplateFields.new(
  #       name: "Booking booked by notification",
  #       fields: common_fields
  #     ),
  #     {"bookings", "booking_notify"} => TemplateFields.new(
  #       name: "Booking notification",
  #       fields: common_fields + [
  #         {name: "start_time", description: "The start time of the booking"},
  #       ]
  #     ),
  #   }
  # end
  #
  abstract def template_fields : Hash(Tuple(String, String), TemplateFields)

  alias TemplateFields = NamedTuple(
    # Human readable name
    # example: "Booking booked by notification"
    name: String,

    # List of fields that can be used in the template
    # name should match args used for #send_template
    # description should be a human readable description of the field
    # example:
    # [
    #   {name: "booking_id", description: "The ID of the booking"},
    # ]
    fields: Array(NamedTuple(name: String, description: String)))
end
