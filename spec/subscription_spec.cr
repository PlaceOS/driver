require "./helper"

describe EngineDriver::Subscriptions do
  it "should subscribe to a channel" do
    subs = EngineDriver::Subscriptions.new
    subs.channel "test" do |sub, message|
    end
  end
end
