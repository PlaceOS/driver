require "action-controller/logger"

class PlaceOS::Driver
  LOG_FORMATTER = ActionController.default_formatter
  VERSION       = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}
end
