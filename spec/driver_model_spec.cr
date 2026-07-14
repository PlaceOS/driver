require "./helper"

describe PlaceOS::Driver::DriverModel::Metadata do
  # the compiled driver emits this JSON via the `-m` / `-d` flags. Here we grab
  # the same output from the test build and ensure driver_model.cr can parse it.
  metadata_json = {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.metadata

  it "parses the metadata emitted by the test build" do
    meta = PlaceOS::Driver::DriverModel::Metadata.from_json(metadata_json)
    meta.should be_a(PlaceOS::Driver::DriverModel::Metadata)
    meta.implements.should_not be_empty
  end

  it "reports the driver library version" do
    meta = PlaceOS::Driver::DriverModel::Metadata.from_json(metadata_json)

    versions = meta.versions.should_not be_nil
    versions["driver"].should eq(PlaceOS::Driver::VERSION)
  end

  it "round-trips the metadata without dropping the versions field" do
    meta = PlaceOS::Driver::DriverModel::Metadata.from_json(metadata_json)
    reparsed = PlaceOS::Driver::DriverModel::Metadata.from_json(meta.to_json)
    reparsed.versions.should eq({"driver" => PlaceOS::Driver::VERSION})
  end
end
