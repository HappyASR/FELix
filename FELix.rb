#!/usr/bin/env ruby
#   FELix.rb
#   Copyright 2014 Bartosz Jankowski
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
require 'hex_string'
require 'hexdump'
require 'colorize'
require 'optparse'
require 'libusb'
require 'bindata'

require_relative 'FELStructs'

#Routines
# 1. Write (--> send | <-- recv)
# --> AWUSBRequest(AW_USB_WRITE, len)
# --> WRITE(len)
# <-- READ(13) -> AWUSBResponse
# (then)
# 2. Read
# --> AWUSBRequest(AW_USB_READ, len)
# <-- READ(len)
# <-- READ(13) -> AWUSBResponse
# (then)
# 3. Read status
# --> AWUSBRequest(AW_USB_READ, 8)
# <-- READ(8)
# <-- READ(13) -> AWUSBResponse

# Flash process (A31s)
# 1. FEL_R_VERIFY_DEVICE
# 2. FEL_RW_FES_TRANSMITE: Get FES (upload flag)
# 3. FEL_R_VERIFY_DEVICE
# 4. FEL_RW_FES_TRANSMITE: Flash new FES (download flag)
# 5. FES_DOWN (No write) (00 00 00 00 | 00 00 10 00 | 00 00 04 7f 01 00) [SUNXI_EFEX_TAG_ERASE|SUNXI_EFEX_TAG_FINISH]
# 6. FEL_R_VERIFY_DEVICE
# 7. FES_VERIFY_STATUS (tail 04 7f 00 00) [SUNXI_EFEX_TAG_ERASE]
# 8. FES_DOWN (write sunxi_mbr.fex, whole file at once => 16384 * 4 copies bytes size)
#                                  (00 00 00 00 00 00 00 00 01 00 01 7f 01 00) [SUNXI_EFEX_TAG_MBR|SUNXI_EFEX_TAG_FINISH]
# 9. FES_VERIFY_STATUS (tail 01 7f 00 00) [SUNXI_EFEX_TAG_MBR]
# (...)


# 0x206 data80
# --> (16) FES_DOWN (0x206): 06 02 00 00 |00 00 00 00| 10 00 00 00 |04 7f 01 00  SUNXI_EFEX_TAG_ERASE|SUNXI_EFEX_TAG_FINISH
# --> (16) FES_DOWN (0x206): 06 02 00 00 |00 00 00 00| 00 00 01 00 |01 7f 01 00  SUNXI_EFEX_TAG_MBR|SUNXI_EFEX_TAG_FINISH
# Then following sequence (write in chunks of 128 bytes => becase of FES_MEDIA_INDEX_LOG) writing partitons...
# --> (16) FES_DOWN (0x206): 06 02 00 00 |00 80 00 00| 00 00 01 00 |00 00 00 00
# --> (16) FES_DOWN (0x206): 06 02 00 00 |80 80 00 00| 00 00 01 00 |00 00 00 00
# --> (16) FES_DOWN (0x206): 06 02 00 00 |00 81 00 00| 00 00 01 00 |00 00 00 00
# --> (16) FES_DOWN (0x206): 06 02 00 00 |80 81 00 00| 00 00 01 00 |00 00 00 00
# -->                                                 ...
# --> (16) FES_DOWN (0x206): 06 02 00 00 |00 a3 00 00| 00 00 01 00 |00 00 00 00
# --> (16) FES_DOWN (0x206): 06 02 00 00 |80 a3 00 00| 00 00 01 00 |00 00 00 00
# -->                                                 ...
# --> (16) FES_DOWN (0x206): 06 02 00 00 |00 a4 00 00| 00 04 00 00 |00 00 01 00 SUNXI_EFEX_TAG_FINISH

# Convert board id to string
# @param id [Integer] board id
# @return [String] board name or ? if unknown
def board_id_to_str(id)
    case (id >> 8 & 0xFFFF)
    when 0x1610 then "Allwinner A31s"
    when 0x1623 then "Allwinner A10"
    when 0x1625 then "Allwinner A13"
    when 0x1633 then "Allwinner A31"
    when 0x1639 then "Allwinner A80"
    when 0x1650 then "Allwinner A23"
    when 0x1651 then "Allwinner A20"
    else
     "?"
    end
end
# Convert tag mask to string
# @param tags [Integer] tag flag
# @return [String] human readable tags delimetered by |
def tags_to_s(tags)
  r = ""
  FEX_TAGS.each do |k,v|
    next if tags>0 && k == :none
    r << "|" if r.length>0 && tags & v == v
    r << "#{k.to_s}" if tags & v == v
  end
  r
end

# Decode packet
# @param packet [String] packet data without USB header
# @param dir [Symbol] last connection direction (`:read` or `:write`)
# @return [Symbol] direction of the packet
def debug_packet(packet, dir)
    if packet[0..3] == "AWUC" && packet.length == 32
        p = AWUSBRequest.read(packet)
        print "--> (% 5d) " % packet.length
        case p.cmd
        when AW_USB_READ
            print "AWUSBRead".yellow
            dir = :read
        when AW_USB_WRITE
            print "AWUSBWrite".yellow
            dir = :write
        else
            print "AWUnknown (0x%x)".red % p.type
        end
        puts "\t(Prepare for #{dir.to_s} of #{p.len} bytes)"
        #puts p.inspect
    elsif packet[0..7] == "AWUSBFEX"
        p = AWFELVerifyDeviceResponse.read(packet)
        puts "<-- (% 5d) " % packet.length << "AWFELVerifyDeviceResponse".
          yellow << "\t%s, FW: %d, mode: %s" % [ board_id_to_str(p.board), p.fw,
          FEL_DEVICE_MODE.key(p.mode) ]
    elsif packet[0..3] == "AWUS" && packet.length == 13
        p = AWUSBResponse.read(packet)
        puts "<-- (% 5d) " % packet.length << "AWUSBResponse".yellow <<
         "\t0x%x, status %s" % [ p.tag, CSW_STATUS.key(p.csw_status) ]
    else
        return :unk if dir == :unk
        print (dir == :write ? "--> " : "<-- ") << "(% 5d) " % packet.length
        if packet.length == 16
            p = AWFELMessage.read(packet)
            case p.cmd
            when AWCOMMAND[:FEL_R_VERIFY_DEVICE] then puts "FEL_R_VERIFY_DEVICE"
              .yellow <<  " (#{AWCOMMAND[:FEL_R_VERIFY_DEVICE]})"
            when AWCOMMAND[:FES_RW_TRANSMITE]
              p = AWFELFESTrasportRequest.read(packet)
              puts "#{AWCOMMAND.key(p.cmd)}: ".yellow <<
                FES_TRANSMITE_FLAG.key(p.direction).to_s <<
                ", index #{p.media_index}, addr 0x%08x, len %d" % [p.address,
                                                                   p.len]
            when AWCOMMAND[:FES_DOWNLOAD], AWCOMMAND[:FES_R_VERIFY_STATUS]
              p = AWFELMessage.read(packet)
              puts "#{AWCOMMAND.key(p.cmd)}".yellow << " (0x%.2X)\n"  % p.cmd <<
                "\ttag: #{p.tag}, %d bytes @ 0x%08x" % [p.len, p.address] <<
                ", flags #{tags_to_s(p.flags)} (0x%04x)" % p.flags
            else
              puts "#{AWCOMMAND.key(p.cmd)}".yellow << " (0x%.2X):"  % p.cmd <<
                "#{packet.to_hex_string[0..46]}"
            end
        elsif packet.length == 8
          p = AWFELStatusResponse.read(packet)
          puts "AWFELStatusResponse\t".yellow <<
            "mark #{p.mark}, tag #{p.tag}, state #{p.state}"
        else
            print "\n"
            Hexdump.dump(packet[0..63])
        end
    end
        dir
end

# Decode USBPcap packets exported from Wireshark in C header format
# e.g. {
# 0x1c, 0x00, 0x10, 0x60, 0xa9, 0x95, 0x00, 0xe0, /* ...`.... */
# 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, /* ........ */
# 0x01, 0x01, 0x00, 0x0d, 0x00, 0x80, 0x02, 0x00, /* ........ */
# 0x00, 0x00, 0x00, 0x02                          /* .... */
# };
# @param file [String] file name
def debug_packets(file)
  return if file.nil?

  packets = Array.new
  contents = File.read(file)
  contents.scan(/^.*?{(.*?)};/m) do |packet|
    hstr = ""
    packet[0].scan(/0x([0-9A-Fa-f]{2})/m) { |hex| hstr << hex[0] }
    #Strip USB header
    begin
      packets << hstr.to_byte_string[27..-1] if hstr.to_byte_string[27..-1] != nil
    rescue RuntimeError => e
      puts "Error : (#{e.message}) at #{e.backtrace[0]}"
      puts "Failed to decode packet: (#{hstr.length / 2}), #{hstr}"
    end
  end

  dir = :unk
  packets.each do |packet|
      next if packet.length < 4
      dir = debug_packet(packet, dir)
  end
end

# Print out the suitable devices
# @param devices [Array<LIBUSB::Device>] list of the devices
# @note the variable i is used for --device parameter
def list_devices(devices)
  i = 0
  devices.each do |d|
    puts "* %2d: (port %d) FEL device %d@%d %x:%x" % [++i, d.port_number,
        d.bus_number, d.device_address, d.idVendor, d.idProduct]
  end
end

# Send a request
# @param handle [LIBUSB::DevHandle] a device handle
# @param data binary data
# @return [AWUSBResponse] or nil if fails
def send_request(handle, data)
# 1. Send AWUSBRequest to inform what we want to do (write/read/how many data)
  begin
    request = AWUSBRequest.new
    request.len = data.length
    debug_packet(request.to_binary_s, :write) if $options[:verbose]
    r = handle.bulk_transfer(:dataOut => request.to_binary_s, :endpoint =>
     $usb_out)
    puts "Sent ".green << "#{r}".yellow << " bytes".green if $options[:verbose]

# 2. Send a proper data
    debug_packet(data, :write) if $options[:verbose]
    r = handle.bulk_transfer(:dataOut => data, :endpoint => $usb_out)
    puts "Sent ".green << data.length.to_s.yellow << " bytes".green if $options[:verbose]
  rescue => e
    puts "Failed to send ".red << data.length.to_s.yellow << " bytes".red <<
    " (" << e.message << ")"
    return nil
  end
# 3. Get AWUSBResponse
  begin
    r = handle.bulk_transfer(:dataIn => 13, :endpoint => $usb_in)
    debug_packet(r, :read) if $options[:verbose]
    puts "Received ".green << "#{r.length}".yellow << " bytes".green if $options[:verbose]
    r
  rescue => e
    puts "Failed to receive ".red << "AWUSBResponse".yellow << " bytes".red <<
    " (" << e.message << ")"
    nil
  end
end

# Read data
# @param handle [LIBUSB::DevHandle] a device handle
# @param len expected length of data
# @return [String] binary data or nil if fail
def recv_request(handle, len)
  # 1. Send AWUSBRequest to inform what we want to do (write/read/how many data)
  begin
    request = AWUSBRequest.new
    request.len = len
    request.cmd = AW_USB_READ
    debug_packet(request.to_binary_s, :write) if $options[:verbose]
    r = handle.bulk_transfer(:dataOut => request.to_binary_s, :endpoint => $usb_out)
    puts "Sent ".green << "#{r}".yellow << " bytes".green if $options[:verbose]
  rescue => e
    puts "Failed to send AWUSBRequest ".red << " (" << e.message << ")"
    return nil
  end
  # 2. Read data of length we specified in request
  begin
    recv_data = handle.bulk_transfer(:dataIn => len, :endpoint => $usb_in)
    debug_packet(recv_data, :read) if $options[:verbose]
  # 3. Get AWUSBResponse
    r = handle.bulk_transfer(:dataIn => 13, :endpoint => $usb_in)
    puts "Received ".green << "#{r.length}".yellow << " bytes".green if $options[:verbose]
    debug_packet(r, :read) if $options[:verbose]
    recv_data
  rescue => e
    puts "Failed to receive ".red << "#{len}".yellow << " bytes".red <<
    " (" << e.message << ")"
    nil
  end

end


# Clean up on and finish program
# @param handle [LIBUSB::DevHandle] a device handle
def bailout(handle)
  handle.close if handle
  exit
end

# Get device status
# @param handle [LIBUSB::DevHandle] a device handle
# @return [AWFELVerifyDeviceResponse] device status
# @raise [String]
def felix_get_device_info(handle)
  data = send_request(handle, AWFELStandardRequest.new.to_binary_s)
  if data == nil
    raise "Failed to send request (data: #{data})"
  end
  data = recv_request(handle, 32)
  if data == nil || data.length != 32
    raise "Failed to receive device info (data: #{data})"
  end
  info = AWFELVerifyDeviceResponse.read(data)
  data = recv_request(handle, 8)
  if data == nil || data.length != 8
    raise "Failed to receive device status (data: #{data})"
  end
  status = AWFELStatusResponse.read(data)
  if status.state > 0
    raise "Command failed (Status #{status.state})"
  end
  info
end

# Erase NAND flash
# @param handle [LIBUSB::DevHandle] a device handle
# @return [AWFESVerifyStatusResponse] operation status
# @raise [String] error name
# @note Device must be in FES mode
def felix_format_device(handle)
  request = AWFELMessage.new
  request.address = 0
  request.len = 16
  request.flags = FEX_TAGS[:erase] | FEX_TAGS[:finish]
  data = send_request(handle, request.to_binary_s)
  if data == nil
    raise "Failed to send request (data: #{data})"
  end
  data = recv_request(handle, 8)
  if data == nil || data.length != 8
    raise "Failed to receive device status (data: #{data})"
  end
  status = AWFELStatusResponse.read(data)
  if status.state > 0
    raise "Command failed (Status #{status.state})"
  end
  felix_verify_status(handle, :erase)
end

# Verify last operation status
# @param handle [LIBUSB::DevHandle] a device handle
# @param tag [Symbol] operation tag (one or more of FEX_TAGS)
# @return [AWFESVerifyStatusResponse] device status
# @raise [String] error name
def felix_verify_status(handle, tags)
  request = AWFELMessage.new
  request.cmd = AWCOMMAND[:FES_R_VERIFY_STATUS]
  request.address = 0
  request.len = 0
  request.flags = FEX_TAGS[tag]
  data = send_request(handle, request.to_binary_s)
  if data == nil
    raise "Failed to send verify request"
  end
  data = recv_request(handle, 12)
  if data == nil
    raise "Failed to receive verify request (no data)"
  elsif data.length != 12
    raise "Failed to receive verify request (data len #{data.length} != 12)"
  end
  AWFESVerifyStatusResponse.read(data)
end

# Read memory from device
# @param handle [LIBUSB::DevHandle] a device handle
# @param address [Integer] memory address to read from
# @param length [Integer] size of data
# @param tag [Symbol] operation tag (one or more of FEX_TAGS)
# @return [String] requested data
# @raise [String] error name
# @note Use in AL_VERIFY_DEV_MODE_FEL
def felix_read(handle, address, length, tags=[])
  request = AWFELMessage.new
  request.cmd = AWCOMMAND[:FEL_R_UPLOAD]
  request.address = address
  request.len = length
  tags.each {|t| request.flags |= FEX_TAGS[t]}
  data = send_request(handle, request.to_binary_s)
  if data == nil
    raise "Failed to send verify request"
  end
  output = recv_request(handle, length)
  if output == nil
    raise "Failed to receive verify request (no data)"
  elsif output.length != length
    raise "Failed to receive verify request (data len #{data.length} != #{length})"
  end
  data = recv_request(handle, 8)
  if data == nil || data.length != 8
    raise "Failed to receive device status (data: #{data})"
  end
  status = AWFELStatusResponse.read(data)
  if status.state > 0
    raise "Command failed (Status #{status.state})"
  end
  output
end

$options = {}
puts "FEL".red << "ix " << FELIX_VERSION << " by Lolet"
puts "Warning:".red << "I don't give any warranty on this software"
puts "You use it at own risk!"
puts "----------------------"

begin
  ComputerInteger = /(?:0x[\da-f]+(?:_[\da-f]+)*|\d+(?:_\d+)*)/
  OptionParser.new do |opts|
      opts.banner = "Usage: FELix.rb action [options]"

      opts.on("--devices", "List the devices") do |v|
          devices = LIBUSB::Context.new.devices(:idVendor => 0x1f3a,
           :idProduct => 0xefe8)
          puts "No device found in FEL mode!" if devices.empty?
          list_devices(devices)
          exit
      end
      opts.on("-d", "--device number", Integer,
        "Select device number (default 0)") { |id| $options[:device] = id }
      opts.on("-i", "--info", "Get device info") { $options[:action] =
        :device_info }
      opts.on("--format", "Erase NAND Flash") { $options[:action] = :format }
      opts.on("--debug path", String, "Decodes packets from Wireshark dump") do |f|
        debug_packets(f)
        exit
      end
      opts.on("-r", "--read file", String, "Read memory to file. Use with" <<
      " --address and --length") do |f|
         $options[:action] = :read
         $options[:file] = f
       end
      opts.on("-a", "--address addr", ComputerInteger, "Address used for " <<
      "operation") do |a|
        $options[:address] = a[0..1] == "0x" ? Integer(a, 16) : a.to_i
      end
      opts.on("-l", "--length len", ComputerInteger, "Length of data") do |l|
        $options[:length] = l[0..1] == "0x" ? Integer(l, 16) : l.to_i
      end
      opts.on_tail("-v", "--verbose", "Verbose traffic") do
        $options[:verbose] = true
      end
      opts.on_tail("--version", "Show version") do
        puts FELIX_VERSION
        exit
      end
  end.parse!
  raise OptionParser::MissingArgument if($options[:action] == :read &&
    ($options[:length] == nil || $options[:address] == nil))
rescue OptionParser::MissingArgument
  puts "Missing argument. Type FELix.rb --help to see usage"
  exit
end

usb = LIBUSB::Context.new
devices = usb.devices(:idVendor => 0x1f3a, :idProduct => 0xefe8)
if devices.empty?
    puts "No device found in FEL mode!"
    exit
end

if devices.size > 1 && $options[:device] == nil # If there's more than one
                                                # device list and ask to select
    puts "Found more than 1 device (use --device <number> parameter):"
    exit
else
    $options[:device] ||= 0
    dev = devices[$options[:device]]
    print "* Connecting to device at port %d, FEL device %d@%d %x:%x" % [
        dev.port_number, dev.bus_number, dev.device_address, dev.idVendor,
        dev.idProduct]
end
# Setup endpoints
$usb_out = dev.endpoints.select { |e| e.direction == :out }[0]
$usb_in = dev.endpoints.select { |e| e.direction == :in }[0]

begin
    $handle = dev.open
    #detach_kernel_driver(0)
    $handle.claim_interface(0)
    puts "\t[OK]".green
rescue
    puts "\t[FAIL]".red
    bailout($handle)
end
case $options[:action]
when :device_info # case for FEL_R_VERIFY_DEVICE
  begin
    info = felix_get_device_info($handle)
    info.each_pair do |k, v|
      print "%-40s" % k.to_s.yellow
      case k
      when :board then puts board_id_to_str(v)
      when :mode then puts FEL_DEVICE_MODE.key(v)
      when :data_flag, :data_length, :data_start_address then puts "0x%08x" % v
      else
        puts "#{v}"
      end
    end
  rescue => e
    puts "Failed to receive device info (#{e.message})"
  end
when :format
  begin
    data = felix_format_device($handle)
    puts "Device response:" << "#{data.last_error}".yellow
  rescue => e
    puts "Failed to format device (#{e.message})"
  end
when :read
  begin
    data = felix_read($handle, $options[:address], $options[:length])
    File.open($options[:file], "w") { |f| f.write(data) }
  rescue => e
    puts "Failed to read data (#{e.message}) at #{e.backtrace[0]}"
  end
else
  puts "No action specified"
end

bailout($handle)
