require_relative "test_helper"
require "rbconfig"
require "tempfile"

require_relative "../lib/witsnet"
require_relative "support/linux_packet_socket"
require_relative "support/privileged_command"

class WitsnetControllerStartsEthernetTest < Minitest::Test
  CONTROLLER_SCRIPT = ENV.fetch(
    "WITSNET_CONTROLLER_SCRIPT",
    File.expand_path("../bin/witsnet_controller", __dir__)
  )

  def teardown
    LinuxPacketSocket.stop_capture(@capture_session)
    @stderr_file&.close!

    return unless defined?(@controller_pid) && @controller_pid

    PrivilegedCommand.capture3("kill", "-TERM", @controller_pid.to_s)
    Process.wait(@controller_pid)
  rescue Errno::ESRCH, Errno::ECHILD, PrivilegedCommand::Error
    nil
  end

  def test_controller_script_sends_a_witsnet_ethernet_frame_in_eth_mode
    assert File.exist?(CONTROLLER_SCRIPT),
      "Expected WiTSnet Controller script at #{CONTROLLER_SCRIPT}"

    with_veth_pair do |controller_peer, device_peer|
      @capture_session = LinuxPacketSocket.start_capture(
        interface_name: device_peer.name,
        ethertype: ETHERTYPE,
        timeout_seconds: 2
      )
      @stderr_file = Tempfile.new("witsnet_controller_eth_stderr")

      @controller_pid = PrivilegedCommand.spawn(
        RbConfig.ruby,
        CONTROLLER_SCRIPT,
        "eth://#{controller_peer.name}",
        out: File::NULL,
        err: @stderr_file.path
      )

      frame = captured_frame

      refute_nil frame,
        "Expected #{CONTROLLER_SCRIPT} to send a WiTSnet Ethernet frame on #{controller_peer.name} in eth:// mode#{stderr_suffix}"

      assert_equal controller_peer.mac_address, frame.source_mac
      assert_equal ETHERTYPE.to_i(16), frame.ethertype
      assert_equal "witsnet", frame.payload
    end
  end

  private

  def with_veth_pair(&block)
    LinuxPacketSocket.with_veth_pair(&block)
  rescue LinuxPacketSocket::RequirementError, PrivilegedCommand::Error => e
    skip e.message
  end

  def captured_frame
    LinuxPacketSocket.read_captured_frame(@capture_session)
  rescue LinuxPacketSocket::CommandError => e
    @capture_error = e.message
    nil
  ensure
    @capture_session = nil
  end

  def stderr_suffix
    details = []

    stderr = @stderr_file && File.read(@stderr_file.path).strip
    details << "stderr: #{stderr}" if stderr && !stderr.empty?
    details << "capture: #{@capture_error}" if defined?(@capture_error) && @capture_error && !@capture_error.empty?

    details.empty? ? "" : "; #{details.join('; ')}"
  end
end
