require "minitest/autorun"
require "rbconfig"
require "socket"
require "timeout"

require_relative "../lib/witsnet"

class WitsnetDeviceRunningTest < Minitest::Test
  DEVICE_HOST = "127.0.0.1"
  DEVICE_SCRIPT = ENV.fetch(
    "WITSNET_DEVICE_SCRIPT",
    File.expand_path("../bin/witsnet_device", __dir__)
  )

  def teardown
    return unless defined?(@device_pid) && @device_pid

    Process.kill("TERM", @device_pid)
    Process.wait(@device_pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def test_device_script_starts_and_binds_the_witsnet_udp_port
    assert File.exist?(DEVICE_SCRIPT),
      "Expected WiTSnet Device script at #{DEVICE_SCRIPT}"

    assert udp_port_available?,
      "Expected UDP port #{UDP_PORT} to be free before starting the Device"

    @device_pid = Process.spawn(
      RbConfig.ruby,
      DEVICE_SCRIPT,
      out: File::NULL,
      err: File::NULL
    )

    assert wait_until_device_binds_udp_port,
      "Expected #{DEVICE_SCRIPT} to bind UDP #{DEVICE_HOST}:#{UDP_PORT}"
  end

  private

  def wait_until_device_binds_udp_port
    Timeout.timeout(2) do
      loop do
        return false if device_exited?
        return true unless udp_port_available?

        sleep 0.05
      end
    end
  rescue Timeout::Error
    false
  end

  def udp_port_available?
    socket = UDPSocket.new
    socket.bind(DEVICE_HOST, UDP_PORT)
    true
  rescue Errno::EADDRINUSE
    false
  ensure
    socket&.close
  end

  def device_exited?
    _, status = Process.waitpid2(@device_pid, Process::WNOHANG)
    !status.nil?
  rescue Errno::ECHILD
    true
  end
end
