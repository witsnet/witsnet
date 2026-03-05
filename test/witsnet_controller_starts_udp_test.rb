require_relative "test_helper"
require "rbconfig"
require "socket"
require "tempfile"
require "timeout"

class WitsnetControllerStartsUdpTest < Minitest::Test
  DEVICE_HOST = "127.0.0.1"
  CONTROLLER_SCRIPT = ENV.fetch(
    "WITSNET_CONTROLLER_SCRIPT",
    File.expand_path("../bin/witsnet_controller", __dir__)
  )

  def teardown
    @device_socket&.close
    @device_connection&.close
    @device_server&.close

    return unless defined?(@controller_pid) && @controller_pid

    Process.kill("TERM", @controller_pid)
    Process.wait(@controller_pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def test_controller_script_sends_a_udp_packet_to_the_device_in_udp_mode
    assert File.exist?(CONTROLLER_SCRIPT),
      "Expected WiTSnet Controller script at #{CONTROLLER_SCRIPT}"

    @device_socket = UDPSocket.new
    @device_socket.bind(DEVICE_HOST, 0)
    device_port = @device_socket.addr[1]

    @controller_pid = Process.spawn(
      RbConfig.ruby,
      CONTROLLER_SCRIPT,
      "udp://#{DEVICE_HOST}:#{device_port}",
      out: File::NULL,
      err: File::NULL
    )

    packet = wait_for_udp_packet

    assert_equal "witsnet", packet,
      "Expected #{CONTROLLER_SCRIPT} to send UDP payload to #{DEVICE_HOST}:#{device_port} in udp:// mode"
  end

  def test_controller_script_sends_tcp_data_to_the_device_in_tcp_mode
    assert File.exist?(CONTROLLER_SCRIPT),
      "Expected WiTSnet Controller script at #{CONTROLLER_SCRIPT}"

    @device_server = TCPServer.new(DEVICE_HOST, 0)
    device_port = @device_server.local_address.ip_port

    @controller_pid = Process.spawn(
      RbConfig.ruby,
      CONTROLLER_SCRIPT,
      "tcp://#{DEVICE_HOST}:#{device_port}",
      out: File::NULL,
      err: File::NULL
    )

    payload = wait_for_tcp_payload

    assert_equal "witsnet", payload,
      "Expected #{CONTROLLER_SCRIPT} to send TCP payload to #{DEVICE_HOST}:#{device_port} in tcp:// mode"
  end

  def test_controller_script_exits_with_usage_on_invalid_transport_uri
    assert File.exist?(CONTROLLER_SCRIPT),
      "Expected WiTSnet Controller script at #{CONTROLLER_SCRIPT}"

    stderr_file = Tempfile.new("witsnet_controller_stderr")

    @controller_pid = Process.spawn(
      RbConfig.ruby,
      CONTROLLER_SCRIPT,
      "http://#{DEVICE_HOST}",
      out: File::NULL,
      err: stderr_file.path
    )

    status = wait_for_controller_exit

    refute_nil status,
      "Expected #{CONTROLLER_SCRIPT} to exit for invalid transport URI"

    @controller_pid = nil

    assert_equal 1, status.exitstatus,
      "Expected #{CONTROLLER_SCRIPT} to exit with status 1 for invalid transport URI"

    stderr_file.rewind
    assert_includes stderr_file.read, "Usage:",
      "Expected #{CONTROLLER_SCRIPT} to print usage when transport URI is invalid"
  ensure
    stderr_file&.close!
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

  def wait_for_controller_exit
    Timeout.timeout(2) do
      loop do
        _, status = Process.waitpid2(@controller_pid, Process::WNOHANG)
        return status if status

        sleep 0.05
      end
    end
  rescue Timeout::Error
    nil
  rescue Errno::ECHILD
    nil
  end

  def wait_for_tcp_payload
    Timeout.timeout(2) do
      loop do
        return nil if controller_exited?

        readable, = IO.select([@device_server], nil, nil, 0.05)
        next unless readable

        connection = @device_server.accept_nonblock(exception: false)
        next if connection == :wait_readable

        @device_connection = connection
        return wait_for_connection_payload
      end
    end
  rescue Timeout::Error
    nil
  end

  def wait_for_connection_payload
    Timeout.timeout(2) do
      loop do
        readable, = IO.select([@device_connection], nil, nil, 0.05)
        next unless readable

        data = @device_connection.read_nonblock(65_535, exception: false)
        next if data == :wait_readable

        return data
      end
    end
  rescue Timeout::Error
    nil
  end
end
