require "json"

abstract class PlaceOS::Driver; end

# The namespace for all PlaceOS standard interfaces
module PlaceOS::Driver::Interface; end

# Common Email templates interface
module PlaceOS::Driver::Interface::MailerTemplates
  # example implementation for multiple templates with the same fields:
  # def template_fields : Array(TemplateFields)
  #   [
  #     {"bookings", "booked_by_notify", "Booking booked by notification"},
  #     {"bookings", "booking_notify", "Booking notification"},
  #   ].each do |template|
  #     TemplateFields.new(
  #       driver: "BookingNotifier",
  #       template: {template[0], template[1]},
  #       name: template[2],
  #       fields: [
  #         {name: "booking_id", description: "The ID of the booking"},
  #       ]
  #     )
  #   end
  # end
  abstract def template_fields : Array(TemplateFields)

  struct TemplateFields
    include JSON::Serializable

    # The driver that this template is for
    # example: "BookingNotifier"
    property driver : String

    # Same as is being used for #send_template
    # example: ["bookings", "booked_by_notify"]
    property template : Tuple(String, String)

    # Human readable name
    # example: "Booking booked by notification"
    property name : String

    # List of fields that can be used in the template
    # name should match args used for #send_template
    # description should be a human readable description of the field
    # example:
    # [
    #   {name: "booking_id", description: "The ID of the booking"},
    # ]
    property fields : Array(NamedTuple(name: String, description: String))

    def trigger(seperator : String = ".")
      template.join(seperator)
    end

    def full_name(seperator : String = ": ")
      "#{driver}#{seperator}#{name}"
    end
  end
end
