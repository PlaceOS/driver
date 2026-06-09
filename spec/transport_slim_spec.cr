require "spec"

# Validates that only the transports implied by the discovery settings are
# compiled into a driver binary:
# * `tcp_port` => TCP + SSH
# * `udp_port` => UDP
# * `uri_base` => HTTP + websocket
# * none defined => logic only
#
# the `-Dplaceos_all_transports` flag forces all transports to be included,
# used by the test-harness as drivers are spec'd against mock TCP servers
private def compile(fixture : String, *flags) : Bool
  output = IO::Memory.new
  status = Process.run(
    "crystal",
    ["build", "--no-codegen", *flags, "./spec/slim_fixtures/#{fixture}"],
    output: output,
    error: output
  )
  puts output.to_s unless status.success? || fixture.includes?("no_ssh")
  status.success?
end

describe "transport slimming" do
  it "compiles a uri_base only driver without the SSH/TCP transports" do
    compile("http_only.cr").should be_true
  end

  it "compiles a driver without discovery settings as logic only" do
    compile("logic_only.cr").should be_true
  end

  it "fails to compile SSH usage when the SSH transport is not included" do
    compile("http_only_no_ssh.cr").should be_false
  end

  it "includes all transports when the placeos_all_transports flag is defined" do
    compile("http_only_no_ssh.cr", "-Dplaceos_all_transports").should be_true
  end
end
