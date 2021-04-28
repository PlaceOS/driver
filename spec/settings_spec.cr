require "./helper"

module AliasTest
  alias Array = ::Array(String)
end

enum TestEnum
  Bob
  Jane
end

class SchemaKlass
  include JSON::Serializable
  property cmd : String
end

alias SomeType = Tuple(String, Bool) | String

describe PlaceOS::Driver::Settings do
  it "should provide simplified access to settings" do
    settings = Helper.settings

    # Test as_x methods
    settings.get { setting(Int32, :integer) }.should eq(1234)
    settings.get { setting(String, :string) }.should eq("hello")
    settings.get { setting?(Int32, :integer) }.should eq(1234)
    settings.get { setting?(String, :string) }.should eq("hello")
    settings.get { setting?(String, :no_exist) }.should eq(nil)

    float = settings.get { setting(Float64, :float) }
    float.should eq(45.0)
    float.class.should eq(Float64)

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

  it "should generate JSON schema from objects" do
    PlaceOS::Driver::Settings.introspect(Array(String)).should eq({type: "array", items: {type: "string"}})
    PlaceOS::Driver::Settings.introspect(AliasTest::Array).should eq({type: "array", items: {type: "string"}})
    PlaceOS::Driver::Settings.introspect(Array(Int32)).should eq({type: "array", items: {type: "integer"}})
    PlaceOS::Driver::Settings.introspect(Array(Float32)).should eq({type: "array", items: {type: "number"}})
    PlaceOS::Driver::Settings.introspect(Array(Bool)).should eq({type: "array", items: {type: "boolean"}})
    PlaceOS::Driver::Settings.introspect(Array(JSON::Any)).should eq({type: "array"})
    PlaceOS::Driver::Settings.introspect(NamedTuple(steve: String)).should eq({type: "object", properties: {steve: {type: "string"}}, required: ["steve"]})
    PlaceOS::Driver::Settings.introspect(TestEnum).should eq({type: "string", enum: ["Bob", "Jane"]})
    PlaceOS::Driver::Settings.introspect(Tuple(String, Bool)).should eq({type: "array", items: [{type: "string"}, {type: "boolean"}]})
    PlaceOS::Driver::Settings.introspect(SomeType).should eq({anyOf: [
      {type: "string"},
      {type: "array", items: [{type: "string"}, {type: "boolean"}]},
    ]})
    PlaceOS::Driver::Settings.introspect(Bool | String).should eq({anyOf: [{type: "boolean"}, {type: "string"}]})
    PlaceOS::Driver::Settings.introspect(SchemaKlass).should eq({type: "object"})
  end

  it "should generate JSON schema from settings access" do
    PlaceOS::Driver::Settings.get { generate_json_schema }.starts_with?(%({"type":"object","properties":{)).should be_true
  end
end
