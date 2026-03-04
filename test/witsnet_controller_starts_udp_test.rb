require_relative "test_helper"
require "rbconfig"
require "socket"
require "timeout"

class WitsnetControllerStartsUdpTest < Minitest::Test
  DEVICE_HOST = "127.0.0.1"
  CONTROLLER_SCRIPT = ENV.fetch(
    "WITSNET_CONTROLLER_SCRIPT",
    File.expand_path("../bin/witsnet_controller", __dir__)
  )

  def teardown
    @device_socket&.close

    return unless defined?(@controller_pid) && @controller_pid

    Process.kill("TERM", @controller_pid)
    Process.wait(@controller_pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def test_controller_script_sends_a_udp_packet_to_the_device
    assert File.exist?(CONTROLLER_SCRIPT),
      "Expected WiTSnet Controller script at #{CONTROLLER_SCRIPT}"

    @device_socket = UDPSocket.new
    @device_socket.bind(DEVICE_HOST, 0)
    device_port = @device_socket.addr[1]

    @controller_pid = Process.spawn(
      {
        "WITSNET_DEVICE_HOST" => DEVICE_HOST,
        "WITSNET_DEVICE_PORT" => device_port.to_s
      },
      RbConfig.ruby,
      CONTROLLER_SCRIPT,
      out: File::NULL,
      err: File::NULL
    )

    packet = wait_for_udp_packet

    assert packet,
      "Expected #{CONTROLLER_SCRIPT} to send a UDP packet to #{DEVICE_HOST}:#{device_port}"
  end

  private

  def wait_for_udp_packet
    Timeout.timeout(2) do
      loop do
        return nil if controller_exited?

        readable, = IO.select([@device_socket], nil, nil, 0.05)
        next unless readable

        return @device_socket.recvfrom_nonblock(65_535).first
      rescue IO::WaitReadable
        next
      end
    end
  rescue Timeout::Error
    nil
  end

  def controller_exited?
    _, status = Process.waitpid2(@controller_pid, Process::WNOHANG)
    !status.nil?
  rescue Errno::ECHILD
    true
  end
end
