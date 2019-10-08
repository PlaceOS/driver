require "./helper"

describe ACAEngine::Driver::Settings do
  it "should provide simplified access to settings" do
    settings = Helper.settings

    # Test as_x methods
    settings.get { setting(Int32, :integer) }.should eq(1234)
    settings.get { setting(String, :string) }.should eq("hello")
    settings.get { setting?(Int32, :integer) }.should eq(1234)
    settings.get { setting?(String, :string) }.should eq("hello")
    settings.get { setting?(String, :no_exist) }.should eq(nil)

    settings[:integer].should eq(1234)
    expect_raises(Exception) do
      settings[:no_exist]
    end

    settings[:integer]?.should eq(1234)
    settings[:no_exist]?.should eq(nil)

    settings.raw(:integer).should eq(1234)
    expect_raises(Exception) do
      settings.raw(:no_exist)
    end

    settings.raw?(:integer).should eq(1234)
    settings.raw?(:no_exist).should eq(nil)
  end

  it "should provide access to complex settings" do
    settings = Helper.settings

    # Test from_json
    settings.get { setting(Array(Int32), :array) }.should eq([12, 34, 54])
    settings.get { setting(Hash(String, String), :hash) }.should eq({"hello" => "world"})
    settings.get { setting?(Array(Int32), :array) }.should eq([12, 34, 54])
    settings.get { setting?(Hash(String, String), :hash) }.should eq({"hello" => "world"})
    settings.get { setting?(Hash(String, String), :no_exist) }.should eq(nil)
  end

  it "should grab deep settings" do
    settings = Helper.settings

    settings.get { setting(String, :hash, :hello) }.should eq("world")
    settings.get { setting?(String, :hash, :hello) }.should eq("world")
    settings.get { setting?(String, :hash, :no_exist) }.should eq(nil)

    settings.raw(:hash, :hello).should eq("world")
    expect_raises(Exception) do
      settings.raw(:hash, :no_exist)
    end

    settings.raw?(:hash, :hello).should eq("world")
    settings.raw?(:hash, :no_exist).should eq(nil)
  end
end
