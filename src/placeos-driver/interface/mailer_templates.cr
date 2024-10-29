abstract class PlaceOS::Driver; end

# The namespace for all PlaceOS standard interfaces
module PlaceOS::Driver::Interface; end

# Common Email templates interface
module PlaceOS::Driver::Interface::MailerTemplates
  #
  # example implementation for multiple templates with shared fields:
  #
  # def template_fields : Array(TemplateFields)
  #   common_fields = [
  #     {name: "booking_id", description: "The ID of the booking"},
  #   ]

  #   [
  #     TemplateFields.new(
  #       trigger: {"bookings", "booked_by_notify"},
  #       name: "Booking booked by notification",
  #       fields: common_fields
  #     ),
  #     TemplateFields.new(
  #       trigger: {"bookings", "booking_notify"},
  #       name: "Booking notification",
  #       fields: common_fields + [
  #         {name: "start_time", description: "The start time of the booking"},
  #       ]
  #     ),
  #   ]
  # end
  #
  abstract def template_fields : Array(TemplateFields)

  alias TemplateFields = NamedTuple(
    # The same as is being used for #send_template.
    # example: {"bookings", "booked_by_notify"}
    trigger: Tuple(String, String),

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
