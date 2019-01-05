require "./helper"

describe EngineDriver::Subscriptions do
  it "should subscribe to a channel" do
    in_callback = false
    sub_passed = nil
    message_passed = nil
    channel = Channel(Nil).new

    subs = EngineDriver::Subscriptions.new
    subscription = subs.channel "test" do |sub, message|
      sub_passed = sub
      message_passed = message
      in_callback = true
      channel.close
    end
    EngineDriver::Storage.redis_pool.publish("engine\x02test", "whatwhat")
    channel.receive?

    in_callback.should eq(true)
    message_passed.should eq("whatwhat")
    sub_passed.should eq(subscription)
  end
end
