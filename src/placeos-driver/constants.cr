require "action-controller/logger"

class PlaceOS::Driver
  LOG_FORMAT    = ENV["PLACE_LOG_FORMAT"]?.presence || "JSON"
  LOG_FORMATTER = LOG_FORMAT == "JSON" ? ActionController.json_formatter : ActionController.default_formatter
  VERSION       = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}
end
