require_relative "test_helper"
require "rbconfig"
require "tempfile"
require "timeout"

require_relative "../lib/witsnet"
require_relative "support/linux_packet_socket"
require_relative "support/privileged_command"

class WitsnetDeviceStartsEthernetTest < Minitest::Test
  DEVICE_SCRIPT = ENV.fetch(
    "WITSNET_DEVICE_SCRIPT",
    File.expand_path("../bin/witsnet_device", __dir__)
  )

  def teardown
    @stderr_file&.close!

    return unless defined?(@device_pid) && @device_pid

    PrivilegedCommand.capture3("kill", "-TERM", @device_pid.to_s)
    Process.wait(@device_pid)
  rescue Errno::ESRCH, Errno::ECHILD, PrivilegedCommand::Error
    nil
  end

  def test_device_script_opens_a_witsnet_packet_socket_in_ethernet_mode
    assert File.exist?(DEVICE_SCRIPT),
      "Expected WiTSnet Device script at #{DEVICE_SCRIPT}"

    with_veth_pair do |controller_peer, device_peer|
      @stderr_file = Tempfile.new("witsnet_device_eth_stderr")

      @device_pid = PrivilegedCommand.spawn(
        RbConfig.ruby,
        DEVICE_SCRIPT,
        "eth://#{device_peer.name}",
        out: File::NULL,
        err: @stderr_file.path
      )

      assert wait_until_device_opens_packet_socket(device_peer.name),
        "Expected #{DEVICE_SCRIPT} to open a WiTSnet packet socket on #{device_peer.name} in eth:// mode#{stderr_suffix}"

      LinuxPacketSocket.send_frame_via_helper(
        interface_name: controller_peer.name,
        destination_mac: device_peer.mac_address,
        source_mac: controller_peer.mac_address,
        ethertype: ETHERTYPE,
        payload: "witsnet"
      )

      assert device_stays_running_after_frame?,
        "Expected #{DEVICE_SCRIPT} to stay running after receiving a WiTSnet Ethernet frame#{stderr_suffix}"
    end
  end

  private

  def with_veth_pair(&block)
    LinuxPacketSocket.with_veth_pair(&block)
  rescue LinuxPacketSocket::RequirementError, PrivilegedCommand::Error => e
    skip e.message
  end

  def wait_until_device_opens_packet_socket(interface_name)
    Timeout.timeout(2) do
      loop do
        return false if device_exited?
        return true if LinuxPacketSocket.packet_socket_bound_on_interface?(
          interface_name: interface_name,
          ethertype: ETHERTYPE
        )

        sleep 0.05
      end
    end
  rescue Timeout::Error, LinuxPacketSocket::RequirementError
    false
  end

  def device_stays_running_after_frame?
    Timeout.timeout(0.5) do
      loop do
        return false if device_exited?

        sleep 0.05
      end
    end
  rescue Timeout::Error
    true
  end

  def device_exited?
    _, status = Process.waitpid2(@device_pid, Process::WNOHANG)
    return false if status.nil?

    @device_pid = nil
    true
  rescue Errno::ECHILD
    @device_pid = nil
    true
  end

  def stderr_suffix
    return "" unless @stderr_file

    stderr = File.read(@stderr_file.path).strip
    stderr.empty? ? "" : "; stderr: #{stderr}"
  end
end
