require "./helper"

describe ACAEngine::Driver::Proxy::System do
  Spec.before_each do
    storage = ACAEngine::Driver::Storage.new("sys-1234", "system")
    storage.delete "Display/1"
    storage.delete "Display/2"
    storage.delete "Display/3"
    storage.delete "Switcher/1"
  end

  Spec.after_each do
    storage = ACAEngine::Driver::Storage.new("sys-1234", "system")
    storage.delete "Display/1"
    storage.delete "Display/2"
    storage.delete "Display/3"
    storage.delete "Switcher/1"
  end

  it "indicate if a module / driver exists in a system" do
    cs = ACAEngine::Driver::DriverModel::ControlSystem.from_json(%(
        {
          "id": "sys-1234",
          "name": "Tesing System",
          "email": "name@email.com",
          "capacity": 20,
          "features": "in-house-pc projector",
          "bookable": true
        }
    ))

    system = ACAEngine::Driver::Proxy::System.new cs, "reply_id"

    system.id.should eq("sys-1234")
    system.name.should eq("Tesing System")
    system.email.should eq("name@email.com")
    system.capacity.should eq(20)
    system.features.should eq("in-house-pc projector")
    system.bookable.should eq(true)

    system.exists?(:Display_1).should eq(false)

    # Create some virtual systems
    storage = ACAEngine::Driver::Storage.new(cs.id, "system")
    storage["Display/1"] = "mod-1234"
    storage["Display/2"] = "mod-5678"
    storage["Display/3"] = "mod-9000"
    storage["Switcher/1"] = "mod-9999"

    system.exists?(:Display_1).should eq(true)
    system.exists?("Display_2").should eq(true)
    system.exists?(:Display, 3).should eq(true)
    system.exists?("Switcher", "1").should eq(true)

    system.modules.should eq(["Display", "Switcher"])
    system.count("Display").should eq(3)
    system.count(:Switcher).should eq(1)
  end

  it "should subscribe to module status" do
    cs = ACAEngine::Driver::DriverModel::ControlSystem.from_json(%(
        {
          "id": "sys-1234",
          "name": "Tesing System",
          "email": "name@email.com",
          "capacity": 20,
          "features": "in-house-pc projector",
          "bookable": true
        }
    ))

    subs = ACAEngine::Driver::Proxy::Subscriptions.new
    system = ACAEngine::Driver::Proxy::System.new cs, "reply_id"
    # Create some virtual systems
    storage = ACAEngine::Driver::Storage.new(cs.id, "system")
    storage["Display/1"] = "mod-1234"
    storage["Display/2"] = "mod-5678"
    storage["Display/3"] = "mod-9000"
    storage["Switcher/1"] = "mod-9999"

    in_callback = false
    sub_passed = nil
    message_passed = nil
    channel = Channel(Nil).new

    mod_store = ACAEngine::Driver::Storage.new("mod-5678")
    mod_store.delete("power")

    subscription = system.subscribe(:Display_2, :power) do |sub, value|
      sub_passed = sub
      message_passed = value
      in_callback = true
      channel.close
    end

    # Subscription should not exist yet - i.e. no lookup
    subscription.module_id.should eq("mod-5678")
    sleep 0.05

    # Update the status
    mod_store["power"] = true
    channel.receive?

    in_callback.should eq(true)
    message_passed.should eq("true")
    sub_passed.should eq(subscription)

    # Test ability to access module state
    system[:Display_2]["power"].as_bool == true

    subs.terminate
    mod_store.delete("power")
  end
end
