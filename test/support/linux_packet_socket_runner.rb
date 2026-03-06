#!/usr/bin/env ruby

require "json"
require "timeout"

require_relative "../../lib/witsnet"
require_relative "linux_packet_socket"

command = ARGV.fetch(0)

case command
when "capture_frame"
  interface_name = ARGV.fetch(1)
  ethertype = ARGV.fetch(2)
  timeout_seconds = Float(ARGV.fetch(3))

  socket = LinuxPacketSocket.open_bound_socket(
    interface_name: interface_name,
    ethertype: ethertype
  )

  begin
    puts "READY"
    STDOUT.flush

    frame = Timeout.timeout(timeout_seconds) do
      loop do
        readable, = IO.select([socket], nil, nil, 0.05)
        next unless readable

        raw_frame = socket.recvfrom_nonblock(65_535).first
        break LinuxPacketSocket.parse_ethernet_frame(raw_frame)
      rescue IO::WaitReadable
        next
      end
    end

    puts JSON.generate(
      destination_mac: frame.destination_mac,
      source_mac: frame.source_mac,
      ethertype: frame.ethertype,
      payload_hex: frame.payload.unpack1("H*")
    )
  ensure
    socket.close
  end
when "send_frame"
  interface_name = ARGV.fetch(1)
  destination_mac = ARGV.fetch(2)
  source_mac = ARGV.fetch(3)
  ethertype = ARGV.fetch(4)
  payload = [ARGV.fetch(5)].pack("H*")

  socket = LinuxPacketSocket.open_socket(ethertype: ethertype)
  begin
    LinuxPacketSocket.send_frame(
      socket: socket,
      interface_name: interface_name,
      destination_mac: destination_mac,
      source_mac: source_mac,
      ethertype: ethertype,
      payload: payload
    )
  ensure
    socket.close
  end
when "wait_bound"
  pid = Integer(ARGV.fetch(1))
  interface_name = ARGV.fetch(2)
  ethertype = ARGV.fetch(3)
  timeout_seconds = Float(ARGV.fetch(4))

  found = Timeout.timeout(timeout_seconds) do
    loop do
      break true if LinuxPacketSocket.process_packet_socket_bound?(
        pid: pid,
        interface_name: interface_name,
        ethertype: ethertype
      )

      break false unless Process.kill(0, pid)

      sleep 0.05
    rescue Errno::ESRCH
      break false
    end
  end

  exit(found ? 0 : 1)
else
  warn "Unknown command: #{command}"
  exit 1
end
