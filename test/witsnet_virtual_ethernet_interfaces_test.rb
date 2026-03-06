require_relative "test_helper"
require "timeout"

require_relative "../lib/witsnet"
require_relative "support/linux_packet_socket"

class WitsnetVirtualEthernetInterfacesTest < Minitest::Test
  def teardown
    LinuxPacketSocket.stop_capture(@capture_session)
  end

  def test_virtual_ethernet_pair_transfers_witsnet_frames_between_two_peers
    with_veth_pair do |left_peer, right_peer|
      @capture_session = LinuxPacketSocket.start_capture(
        interface_name: right_peer.name,
        ethertype: ETHERTYPE,
        timeout_seconds: 2
      )

      LinuxPacketSocket.send_frame_via_helper(
        interface_name: left_peer.name,
        destination_mac: right_peer.mac_address,
        source_mac: left_peer.mac_address,
        ethertype: ETHERTYPE,
        payload: "witsnet"
      )

      frame = LinuxPacketSocket.read_captured_frame(@capture_session)
      @capture_session = nil

      refute_nil frame,
        "Expected a WiTSnet Ethernet frame to arrive on #{right_peer.name}"

      assert_equal right_peer.mac_address, frame.destination_mac
      assert_equal left_peer.mac_address, frame.source_mac
      assert_equal ETHERTYPE.to_i(16), frame.ethertype
      assert_equal "witsnet", frame.payload
    end
  end

  private

  def with_veth_pair(&block)
    LinuxPacketSocket.with_veth_pair(&block)
  rescue LinuxPacketSocket::RequirementError => e
    skip e.message
  end
end
