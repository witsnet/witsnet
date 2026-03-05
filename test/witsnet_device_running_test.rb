require_relative "test_helper"
require "rbconfig"
require "socket"
require "tempfile"
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
      "udp://#{DEVICE_HOST}",
      out: File::NULL,
      err: File::NULL
    )

    assert wait_until_device_binds_udp_port,
      "Expected #{DEVICE_SCRIPT} to bind UDP #{DEVICE_HOST}:#{UDP_PORT} in udp:// mode"
  end

  def test_device_script_starts_and_binds_the_witsnet_tcp_port
    assert File.exist?(DEVICE_SCRIPT),
      "Expected WiTSnet Device script at #{DEVICE_SCRIPT}"

    assert tcp_port_available?,
      "Expected TCP port #{TCP_PORT} to be free before starting the Device"

    @device_pid = Process.spawn(
      RbConfig.ruby,
      DEVICE_SCRIPT,
      "tcp://#{DEVICE_HOST}",
      out: File::NULL,
      err: File::NULL
    )

    assert wait_until_device_binds_tcp_port,
      "Expected #{DEVICE_SCRIPT} to bind TCP #{DEVICE_HOST}:#{TCP_PORT} in tcp:// mode"

    # Give the accept loop time to hit the wait_readable branch before connecting.
    sleep 0.1

    assert wait_until_device_accepts_and_closes_tcp_connection,
      "Expected #{DEVICE_SCRIPT} to accept and close a TCP connection in tcp:// mode"
  end

  def test_device_script_exits_with_usage_on_invalid_transport_uri
    assert File.exist?(DEVICE_SCRIPT),
      "Expected WiTSnet Device script at #{DEVICE_SCRIPT}"

    stderr_file = Tempfile.new("witsnet_device_stderr")

    @device_pid = Process.spawn(
      RbConfig.ruby,
      DEVICE_SCRIPT,
      "http://#{DEVICE_HOST}",
      out: File::NULL,
      err: stderr_file.path
    )

    _, status = Process.waitpid2(@device_pid)
    @device_pid = nil

    assert_equal 1, status.exitstatus,
      "Expected #{DEVICE_SCRIPT} to exit with status 1 for invalid transport URI"

    stderr_file.rewind
    assert_includes stderr_file.read, "Usage:",
      "Expected #{DEVICE_SCRIPT} to print usage when transport URI is invalid"
  ensure
    stderr_file&.close!
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

  def wait_until_device_binds_tcp_port
    Timeout.timeout(2) do
      loop do
        return false if device_exited?
        return true unless tcp_port_available?

        sleep 0.05
      end
    end
  rescue Timeout::Error
    false
  end

  def wait_until_device_accepts_and_closes_tcp_connection
    Timeout.timeout(2) do
      loop do
        return false if device_exited?

        socket = TCPSocket.new(DEVICE_HOST, TCP_PORT)
        socket.write("witsnet")
        socket.flush
        return wait_until_tcp_socket_closed_by_peer(socket)
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
        sleep 0.05
      ensure
        socket&.close
      end
    end
  rescue Timeout::Error
    false
  end

  def wait_until_tcp_socket_closed_by_peer(socket)
    Timeout.timeout(2) do
      loop do
        readable, = IO.select([socket], nil, nil, 0.05)
        next unless readable

        result = socket.read_nonblock(1, exception: false)
        return true if result.nil?
      end
    end
  rescue EOFError, Errno::ECONNRESET
    true
  rescue Timeout::Error
    false
  end

  def tcp_port_available?
    server = TCPServer.new(DEVICE_HOST, TCP_PORT)
    true
  rescue Errno::EADDRINUSE
    false
  ensure
    server&.close
  end

  def device_exited?
    _, status = Process.waitpid2(@device_pid, Process::WNOHANG)
    !status.nil?
  rescue Errno::ECHILD
    true
  end
end
