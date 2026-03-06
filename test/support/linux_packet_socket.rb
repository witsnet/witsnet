require "open3"
require "json"
require "rbconfig"
require "securerandom"
require "socket"

require_relative "privileged_command"

module LinuxPacketSocket
  class Error < StandardError; end
  class RequirementError < Error; end
  class CommandError < Error; end

  VethPeer = Struct.new(:name, :ifindex, :mac_address, keyword_init: true)
  EthernetFrame = Struct.new(
    :destination_mac,
    :source_mac,
    :ethertype,
    :payload,
    keyword_init: true
  )
  CaptureSession = Struct.new(:pid, :stdout, :stderr, keyword_init: true)

  module_function

  def with_veth_pair(prefix: default_veth_prefix)
    assert_linux!
    require_command!("ip")

    left_name, right_name = veth_pair_names(prefix)

    run_ip("link", "add", left_name, "type", "veth", "peer", "name", right_name)
    begin
      run_ip("link", "set", left_name, "up")
      run_ip("link", "set", right_name, "up")

      yield peer(left_name), peer(right_name)
    ensure
      delete_interface(left_name)
    end
  end

  def open_socket(ethertype:)
    Socket.new(Socket::AF_PACKET, Socket::SOCK_RAW, packet_protocol(ethertype))
  rescue Errno::EPERM => e
    raise RequirementError,
      "Opening Linux packet sockets requires CAP_NET_RAW: #{e.message}"
  end

  def open_bound_socket(interface_name:, ethertype:)
    socket = open_socket(ethertype: ethertype)
    socket.bind(packet_sockaddr(interface_name:, ethertype: ethertype))
    socket
  rescue StandardError
    socket&.close
    raise
  end

  def send_frame(socket:, interface_name:, destination_mac:, source_mac:, ethertype:, payload:)
    frame = ethernet_frame(
      destination_mac: destination_mac,
      source_mac: source_mac,
      ethertype: ethertype,
      payload: payload
    )

    socket.send(
      frame,
      0,
      packet_sockaddr(
        interface_name: interface_name,
        ethertype: ethertype,
        mac_address: destination_mac
      )
    )
  end

  def start_capture(interface_name:, ethertype:, timeout_seconds:)
    stdout_reader, stdout_writer = IO.pipe
    stderr_reader, stderr_writer = IO.pipe

    pid = PrivilegedCommand.spawn(
      RbConfig.ruby,
      helper_script_path,
      "capture_frame",
      interface_name,
      normalize_ethertype(ethertype).to_s,
      timeout_seconds.to_s,
      out: stdout_writer,
      err: stderr_writer
    )

    stdout_writer.close
    stderr_writer.close

    ready = stdout_reader.gets&.strip
    return CaptureSession.new(pid: pid, stdout: stdout_reader, stderr: stderr_reader) if ready == "READY"

    error_output = stderr_reader.read.to_s.strip
    Process.wait(pid)

    stdout_reader.close
    stderr_reader.close

    raise RequirementError, error_output.empty? ? "Unable to start privileged packet capture" : error_output
  rescue PrivilegedCommand::Error => e
    stdout_reader&.close
    stderr_reader&.close
    raise RequirementError, e.message
  end

  def read_captured_frame(session)
    payload = session.stdout.read.to_s.strip
    _, status = Process.waitpid2(session.pid)

    raise CommandError, session.stderr.read.to_s.strip unless status.success?

    data = JSON.parse(payload, symbolize_names: true)
    EthernetFrame.new(
      destination_mac: data.fetch(:destination_mac),
      source_mac: data.fetch(:source_mac),
      ethertype: data.fetch(:ethertype),
      payload: [data.fetch(:payload_hex)].pack("H*")
    )
  ensure
    session.stdout.close unless session.stdout.closed?
    session.stderr.close unless session.stderr.closed?
  end

  def stop_capture(session)
    return unless session

    begin
      PrivilegedCommand.capture3("kill", "-TERM", session.pid.to_s)
    rescue PrivilegedCommand::Error
      nil
    end

    begin
      Process.wait(session.pid)
    rescue Errno::ECHILD
      nil
    end

    session.stdout.close unless session.stdout.closed?
    session.stderr.close unless session.stderr.closed?
  end

  def send_frame_via_helper(interface_name:, destination_mac:, source_mac:, ethertype:, payload:)
    stdout, stderr, status = PrivilegedCommand.capture3(
      RbConfig.ruby,
      helper_script_path,
      "send_frame",
      interface_name,
      destination_mac,
      source_mac,
      normalize_ethertype(ethertype).to_s,
      payload.unpack1("H*")
    )

    return stdout if status.success?

    raise RequirementError, privileged_error_message(stderr, stdout)
  rescue PrivilegedCommand::Error => e
    raise RequirementError, e.message
  end

  def wait_until_process_packet_socket_bound(pid:, interface_name:, ethertype:, timeout_seconds:)
    _, stderr, status = PrivilegedCommand.capture3(
      RbConfig.ruby,
      helper_script_path,
      "wait_bound",
      pid.to_s,
      interface_name,
      normalize_ethertype(ethertype).to_s,
      timeout_seconds.to_s
    )

    return status.success? if status.success? || stderr.to_s.empty?

    raise RequirementError, privileged_error_message(stderr, "")
  rescue PrivilegedCommand::Error => e
    raise RequirementError, e.message
  end

  def ethernet_frame(destination_mac:, source_mac:, ethertype:, payload:)
    [
      mac_address_bytes(destination_mac),
      mac_address_bytes(source_mac),
      normalize_ethertype(ethertype),
      payload
    ].pack("a6a6na*")
  end

  def parse_ethernet_frame(frame)
    destination_mac, source_mac, ethertype, payload = frame.unpack("a6a6na*")

    EthernetFrame.new(
      destination_mac: format_mac_address(destination_mac),
      source_mac: format_mac_address(source_mac),
      ethertype: ethertype,
      payload: payload
    )
  end

  def process_packet_socket_bound?(pid:, interface_name:, ethertype:)
    target_inodes = process_socket_inodes(pid)
    target_ifindex = interface_index(interface_name)
    target_protocol = normalize_ethertype(ethertype)

    packet_socket_entries.any? do |entry|
      target_inodes.include?(entry.fetch(:inode)) &&
        entry.fetch(:ifindex) == target_ifindex &&
        entry.fetch(:protocol) == target_protocol
    end
  end

  def packet_socket_bound_on_interface?(interface_name:, ethertype:)
    target_ifindex = interface_index(interface_name)
    target_protocol = normalize_ethertype(ethertype)

    packet_socket_entries.any? do |entry|
      entry.fetch(:ifindex) == target_ifindex &&
        entry.fetch(:protocol) == target_protocol
    end
  end

  def interface_index(interface_name)
    Integer(File.read("/sys/class/net/#{interface_name}/ifindex").strip)
  rescue Errno::ENOENT => e
    raise CommandError, "Unknown interface #{interface_name.inspect}: #{e.message}"
  end

  def mac_address(interface_name)
    File.read("/sys/class/net/#{interface_name}/address").strip.downcase
  rescue Errno::ENOENT => e
    raise CommandError, "Unknown interface #{interface_name.inspect}: #{e.message}"
  end

  def packet_sockaddr(interface_name:, ethertype:, mac_address: nil)
    address = mac_address ? mac_address_bytes(mac_address) : +""

    # sockaddr_ll uses native-endian fields except sll_protocol, which is big-endian.
    [
      Socket::AF_PACKET,
      normalize_ethertype(ethertype),
      interface_index(interface_name),
      0,
      0,
      address.bytesize,
      address.ljust(8, "\x00")
    ].pack("SniSCCa8")
  end

  def packet_protocol(ethertype)
    [normalize_ethertype(ethertype)].pack("n").unpack1("S")
  end

  def normalize_ethertype(ethertype)
    case ethertype
    when String
      token = ethertype.strip
      base = token.match?(/\A(?:0x)?[0-9]+\z/i) ? 10 : 16
      token.delete_prefix("0x").to_i(base)
    else
      Integer(ethertype)
    end
  end

  def mac_address_bytes(mac_address)
    octets = mac_address.split(":")

    unless octets.length == 6 && octets.all? { |octet| octet.match?(/\A[0-9a-fA-F]{2}\z/) }
      raise CommandError, "Invalid MAC address #{mac_address.inspect}"
    end

    octets.map { |octet| octet.to_i(16) }.pack("C6")
  end

  def format_mac_address(raw_address)
    raw_address.bytes.take(6).map { |byte| format("%02x", byte) }.join(":")
  end

  def peer(interface_name)
    VethPeer.new(
      name: interface_name,
      ifindex: interface_index(interface_name),
      mac_address: mac_address(interface_name)
    )
  end

  def process_socket_inodes(pid)
    Dir.glob("/proc/#{pid}/fd/*").filter_map do |fd_path|
      target = File.readlink(fd_path)
      match = target.match(/\Asocket:\[(\d+)\]\z/)
      match[1].to_i if match
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end
  end

  def packet_socket_entries
    File.readlines("/proc/net/packet", chomp: true).drop(1).filter_map do |line|
      fields = line.split
      next if fields.length < 9

      {
        protocol: fields.fetch(3).to_i(16),
        ifindex: fields.fetch(4).to_i,
        inode: fields.fetch(8).to_i
      }
    end
  end

  def assert_linux!
    return if RUBY_PLATFORM.include?("linux")

    raise RequirementError, "Linux packet socket tests require a Linux host"
  end

  def require_command!(command)
    path = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
    return if path.any? { |directory| File.executable?(File.join(directory, command)) }

    raise RequirementError, "Required command #{command.inspect} is not available"
  end

  def run_ip(*arguments)
    stdout, stderr, status = PrivilegedCommand.capture3("ip", *arguments)
    return stdout if status.success?

    message = [stderr, stdout].map(&:strip).reject(&:empty?).first || "unknown error"

    if message.include?("Operation not permitted") || message.include?("Cannot open netlink socket")
      raise RequirementError,
        "Creating virtual Ethernet interfaces requires elevated rights (e.g. sudo, CAP_NET_ADMIN): ip #{arguments.join(' ')} failed with #{message}"
    end

    raise CommandError, "ip #{arguments.join(' ')} failed with #{message}"
  end

  def delete_interface(interface_name)
    PrivilegedCommand.capture3("ip", "link", "delete", interface_name)
  rescue PrivilegedCommand::Error
    nil
  end

  def default_veth_prefix
    "wn#{Process.pid.to_s(36)}#{SecureRandom.hex(2)}"
  end

  def veth_pair_names(prefix)
    base = prefix.gsub(/[^a-zA-Z0-9]/, "").downcase
    base = base[0, 13]

    ["#{base}a", "#{base}b"]
  end

  def helper_script_path
    File.expand_path("linux_packet_socket_runner.rb", __dir__)
  end

  def privileged_error_message(stderr, stdout)
    [stderr, stdout].map(&:to_s).map(&:strip).reject(&:empty?).first || "privileged helper failed"
  end
end
