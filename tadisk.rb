#!/bin/env ruby
#
# TaDisk.rb
#
# A TA 1600 disk image reader.
# Based on information from the ECMA-57 [1] (1976) standard
# Other relevant standards: ECMA-13 [2] (Nov 67) and IBM's "DFSMS Using Magnetic Tapes" [3] (1972)
#
# Motivation: Documentation and archiving of TA1600 5 1/4" floppy disks
#
# Copyright (c) Klaus Kämpf 2022
#
# License: MIT
#
# [1] https://www.ecma-international.org/wp-content/uploads/ECMA-58_2nd_edition_january_1981.pdf
# [2] https://www.ecma-international.org/wp-content/uploads/ECMA-13_4th_edition_december_1985.pdf
# [3] http://publibz.boulder.ibm.com/epubs/pdf/dgt3m300.pdf
#
VERSION = "0.0.1"
SECSIZE = 128
SECPERCYL = 16
BYTESPERCYL = (SECSIZE * SECPERCYL)

# EBCDIC to ASCII translation table
       #     0   1   2   3   4   5   6   7   8   9   A   B   C   D   E   F
EBCDIC = "\x00\xb7\xb7\xb7\xb7\x08\xb7\x7f\xb7\xb7\xb7\xb7\xb7\x0d\xb7\xb7" + # 0x00
         "\xb7\xb7\xb7\xb7\xb7\x0a\x08\xb7\xb7\xb7\xb7\xb7\xb7\xb7\xb7\xb7" + # 0x10
         "\xb7\xb7\xb7\xb7\xb7\x0a\xb7\x1b\xb7\xb7\xb7\xb7\xb7\xb7\xb7\x07" + # 0x20
         "\xb7\xb7\xb7\xb7\xb7\xb7\xb7\xb7\xb7\xb7\xb7\xb7\xb7\xb7\xb7\xb7" + # 0x30
        #0123456789abcdef
        " ·········¢.<(+|" + # 0x40
        "&·········!$*);¬" + # 0x50
        "-/········|,%_>?" + # 0x60
        "·········`:#@'=\"" + # 0x70
        "·abcdefghi·····\xb1" + # 0x80
        "·jklmnopqr······" + # 0x90
        "·~stuvwxyz······" + # 0xa0
        "^·········[]····" + # 0xb0
        "{ABCDEFGHI······" + # 0xc0
        "}JKLMNOPQR······" + # 0xd0
        "\\ÜSTUVWXYZ······" + # 0xe0
        "0123456789······" # 0xf0

def usage message=nil
  STDERR.puts "** Error: #{message}" if message
  STDERR.puts
  STDERR.puts "tadisk - extract data from TA1600 floppy disk images"
  STDERR.puts
  STDERR.puts "Usage:"
  STDERR.puts "  tadisk <image> <command> [<options> ...]"
  STDERR.puts
  STDERR.puts "  tadisk <image> dir         - show directory"
  STDERR.puts "  tadisk <image> dir <name>  - show file details for <name>"
  STDERR.puts "  tadisk <image> copy <name> - copy file <name> to local dir"
  STDERR.puts "  tadisk <image> copy \*     - copy all files to local dir"
  
  exit 1
end

class Disk
  attr_reader :position

  #
  # seek disk position
  #
  # pos = Array of [track, side, sector]
  # track (cylinder) counts from 0
  # side is 0 for front and 1 for back
  # sector counts from 1 (see ECMA 58)
  #
  def seek pos
#    puts "seek #{pos.inspect}"
    case pos
    when Array
      track, side, sector = pos
#      puts "Seek Trk#{track},Sid#{side},Sec#{sector}"
      @position = ((track*(side+1))*SECPERCYL+(side*SECPERCYL)+(sector-1))*SECSIZE
    when Integer
      @position = pos
    else
      raise "Unknown seek value #{pos.inspect}"
    end
    begin
      @disk.seek @position, IO::SEEK_SET
#      STDERR.puts "Seeked to 0x#{@position.to_s(16)}"
    rescue Errno::EINVAL
      STDERR.puts "Cannot seek to #{@position}"
      exit 1
    end
  end

  #
  # get record at current position
  #
  def get size=SECSIZE
    @record = @disk.read size
  end
  
  #
  # get SECSIZE bytes at position
  #
  def get_at pos
    seek pos
    get
  end

  def conv s
    begin
#      STDERR.puts "conv(#{s.inspect})"
      a = s.split('').map{ |c| EBCDIC[c.ord,1] }.join('')
#      STDERR.puts " = >#{a}<"
    end
    a
  end

  #
  # extract label from record
  #
  # returns [ <label identifier>, <label number> ]
  #
  def label record
    record.unpack("a3a1").map { |s| conv s }
  end

  #
  # find label
  #
  # returns label number
  # nil if label not found
  #
  def find what, start = nil
    seek start if start
    l,n = label get
    return n if l == what
    nil
  end

  def copy_s start, length
    @record[start-1,length].unpack1("a*")
  end
  # unpack <length> bytes from current record as string
  # start = start byte, counting from 1 ! (because ECMA does)
  # convert EBCDIC->ASCII
  # return String
  def unpack_s start, length
    s = copy_s start, length
    begin
      conv(s).strip
    rescue Exception => e
      raise "Failed EBCDIC #{s.inspect}: #{e}"
    end
  end

  # unpack <length> bytes from current record as sequence of digits
  # start = start byte, counting from 1 ! (because ECMA does)
  # convert EBCDIC->ASCII
  # return Integer
  def unpack_i start, length
    s = @record[start-1,length].unpack1("a*")
#    STDERR.puts "unpack_i(#{start}:#{length}) = #{s.inspect}"
    begin
      conv(s).to_i
    rescue Exception => e
      STDERR.puts "Failed EBCDIC #{s.inspect}"
      raise e
    end
  end

  #
  # unpack date, 6 bytes (YYMMDD) from start
  #
  # return TaDate
  #
  def unpack_date start
    TaDate.new(unpack_s start,6)
  end

  attr_reader :record

  def initialize imagename
    @filename = imagename
    unless File.readable?(imagename)
      usage "Can't read '#{imagename}'"
    end
    @disk = File.open(imagename, "r")
  end
end

class Volume
  attr_reader :number, :ident, :rlen, :seq, :alloc, :disk
  def initialize disk
    @disk = disk
    #
    # Section 5.6 - Index cylinder, VOL1 at Cyl 0, Side 0, Sector 7
    #
    @number = @disk.find "VOL", [0, 0, 7]
    raise "VOL1 not found" unless @number == "1"
    # @disk is now positioned at VOL1
    # See Section 7.3 for unpack pattern
    @ident = @disk.unpack_s 5,6
    @access = @disk.unpack_s 11,1
    @owner = @disk.copy_s(38,7)
    @seq = @disk.unpack_i 77,2
    @version = @disk.unpack_s 80, 1
    @surface = case @disk.unpack_s(72,1)
               when '', '1' then "Side 0 formatted according to ECMA-54"
               when '2' then "Both sides formatted according to ECMA-59"
               when 'M' then "Both sides formatted according to ECMA-69"
               else
                 @disk.unpack_s(72,1).inspect
               end
    @rlen = case @disk.unpack_s(76,1)
            when '' then 128
            when '1' then 256
            when '2' then 512
            when '3' then 1024
            else
              @disk.unpack_s(76,1).inspect
            end
    @alloc = case @disk.unpack_s(79,1)
             when '' then "Single sided"
             when '1' then "Double sided"
             else
               @disk.unpack_s(79,1).inspect
             end
  end
  def to_s
    "\
    Volume Identifier                 #{@ident.inspect}
    Volume Accessibility Indicator    #{(@access==' ')?'- unrestricted -':@access.inspect}
    Owner                             #{@owner.inspect}
    Surface Indicator                 #{@surface}
    Physical Record Length Identifier #{@rlen} bytes per physical record
    Sector Sequence Indicator         #{@seq.inspect}
    File Label Allocation             #{@alloc}
    Label Standard Version            #{@version.inspect}
"
  end
end

class TaDate
  def initialize s
    @year, @month, @day = s.unpack("a2 a2 a2").map &:to_i
#    STDERR.puts "TaDate(#{s}) = #{self}"
  end
  def to_s
    return "" if @day == 0
    m = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"][@month-1]
    "#{@day}. #{m} 19#{@year}"
  end
end

class Adu
  attr_reader :count, :at
  SIZE = 512
  def self.from_data data
#    STDERR.puts "Ada.from_data"
    adus = []
    off = 0x1c # 28 dez
    loop do
      break if data[off,1] == ' '
#      STDERR.puts data[off,4].split("").map{ |v| "0x#{v.ord.to_s(16)} "}.join("")
      adu = Adu.new(data[off,4])
      break if adu.count == 0
      adus << adu
      off += 4
    end
    adus
  end
  def initialize data_or_count, at=nil
    if at
      @count = data_or_count
      @at = at
    else
      data = data_or_count
      @count = data[0,2].unpack1("n")
      @at = data[0+2,2].unpack1("n")
    end
  end
  def position
    (@at - 4) * SIZE
  end
  def size
    @count * SIZE
  end
  def to_s
    "#{@count} @ 0x#{@at.to_s(16)}(0x#{self.position.to_s(16)})"
  end
end

#---------------------------------------------------------------------

class TaFile
  def initialize entry
    @entry = entry
  end
  def to_s
    @entry.to_s
  end
  def name
    "#{@entry.fullname}: #{@entry.adus.first}"
  end
  def copy name=nil
    File.open(@entry.fullname, "w+") do |f|
      disk = @entry.directory.disk
      @entry.adus.each do |adu|
        disk.seek adu.position
        data = disk.get adu.size
        f.write data
      end
    end
  end
end

#---------------------------------------------------------------------
# Directory


#
# One entry in the main directory
#

class DirEntry
  attr_reader :name, :directory, :adus, :count
  ORGS = { 2 => "SEQ", 4 => "REL", 1 => "INX", 8 => "DIR", 5=> "PGM", 9 => "VCT"}
  def initialize directory, name, data
    @directory = directory
    @name = name
    @org = data[0,1].unpack1("c1")
    @priv = data[2,2].unpack1("n")
    @flags = data[4,1].unpack1("c1")
    @bksz = data[6,2].unpack1("n")
    @lrec = data[8,2].unpack1("n")
    @adus = Adu.from_data data
    @count = 0
    @adus.each { |adu| @count += adu.count }
#    STDERR.puts "DirEntry.new #{@name.inspect} org #{@org} adus #{@adus}"
  end
  def extension
    ORGS[@org]
  end
  def fullname
    "#{@name}.#{extension}"
  end
  def is_system?
    @org == 9
  end
  def is_directory?
    @org == 8
  end
  def to_s
#    FILE     ORG   PRIV  BKSZ  LREC  ADUS  ADU  TYPE
    type = ""
    type << "DEL " if @flags & 0x04 != 0
    type << "COMP " if @flags & 0x20 != 0
    first_adu = @adus.first.at rescue 0
    "  %d  %-8s %3s  %5d   %3d   %3d   %3d  %3d  %s" % [(self.is_system?)?0:@directory.level, @name, extension, @priv, @bksz, @lrec, @count, first_adu, type]
  end
end

#
# Main directory (usually at adu 8, aka 0x800)
#

class TaDir
  attr_reader :disk, :position, :level, :entries
  def initialize disk, adus = nil, parent = nil
    @disk = disk
    @level = (parent.level + 1) rescue 0
    @entries = []
    if adus.nil?              # system dir, get real ADU
#      STDERR.puts "System dir"
      adu = Adu.new(1,8) # system adu, size 1, start at 8
      @disk.seek adu.position
      data = @disk.get adu.size
      adus = Adu.from_data data[256,128]
#      STDERR.puts "Found #{adus.size} adus for system dir"
    end
    data = ""
    adus.each do |adu|
#      STDERR.puts "TaDir read adu #{adu}"
      @disk.seek adu.position
      data += @disk.get adu.size
    end
    number = 0
    loop do
      name = data[number*8, 8].unpack1("A*")
      break if name.empty?
      begin
        number += 1
        entry = DirEntry.new(self, name, data[number*256, 128])
        @entries << entry
        if entry.is_directory?
          @entries += TaDir.new(disk, entry.adus, self).entries
        end
      rescue Exception=>e
        STDERR.puts "Bad directory (after #{@entries.length} entries): #{e}"
        break
      end
      break if number == 15 # 16 * 8 = 128 bytes directory
    end
  end
  def to_s
    count = 0
    s = " LVL FILE     ORG   PRIV  BKSZ  LREC  ADUS  ADU  TYPE\n"
    @entries.each do |entry|
      s += "#{entry}\n"
      count = entry.adus.first.at + entry.count
    end
    s += "TOTAL ADUS ALLOCATED:  #{count}"
  end
  def find name
    @entries.each do |e|
      return e if e.fullname == name.upcase
    end
    nil
  end
  def each &block
    @entries.each do |e|
      yield e
    end
  end
end


class Volume
  attr_reader :number, :ident, :rlen, :seq, :alloc, :disk
  def initialize disk
    @disk = disk
    #
    # Section 5.6 - Index cylinder, VOL1 at Cyl 0, Side 0, Sector 7
    #
    @number = @disk.find "VOL", [0, 0, 7]
    raise "VOL1 not found" unless @number == "1"
    # @disk is now positioned at VOL1
    # See Section 7.3 for unpack pattern
    @ident = @disk.unpack_s 5,6
    @access = @disk.unpack_s 11,1
    @owner = @disk.unpack_s 38,14
    @seq = @disk.unpack_i 77,2
    @version = @disk.unpack_s 80, 1
    @surface = case @disk.unpack_s(72,1)
               when '', '1' then "Side 0 formatted according to ECMA-54"
               when '2' then "Both sides formatted according to ECMA-59"
               when 'M' then "Both sides formatted according to ECMA-69"
               else
                 @disk.unpack_s(72,1).inspect
               end
    @rlen = case @disk.unpack_s(76,1)
            when '' then 128
            when '1' then 256
            when '2' then 512
            when '3' then 1024
            else
              @disk.unpack_s(76,1).inspect
            end
    @alloc = case @disk.unpack_s(79,1)
             when '' then "Single sided"
             when '1' then "Double sided"
             else
               @disk.unpack_s(79,1).inspect
             end
  end
  def to_s
    @ident.inspect
#    Volume Accessibility Indicator    #{(@access==' ')?'- unrestricted -':@access.inspect}
#    Owner                             #{@owner.inspect}
#    Surface Indicator                 #{@surface}
#    Physical Record Length Identifier #{@rlen} bytes per physical record
#    Sector Sequence Indicator         #{@seq.inspect}
#    File Label Allocation             #{@alloc}
#    Label Standard Version            #{@version.inspect}
  end
end

#---------------------------------------------------------------------

#
# Complete TA 1600 disk
#

class TaDisk
  attr_reader :disk, :volume, :directory
  def initialize imagename
    # .img handle
    @disk = Disk.new imagename
    # VOL1 information
    @volume = Volume.new @disk
    puts "Volume: #{@volume}"
    # system dir 
    @directory = TaDir.new @disk
  end
end

#---------------------------------------------------------------------
# main

imagename = nil
command = nil

loop do
  arg = ARGV.shift
  break if arg.nil?
  if imagename.nil?
    imagename = arg
    next
  end
  if command.nil?
    command = arg 
    break
  end
end

usage "image missing" if imagename.nil?
usage "command missing" if command.nil?

begin
  tadisk = TaDisk.new imagename
rescue Exception => e
  STDERR.puts "Can't recognize #{imagename} as disk image: #{e}"
  raise e
end

directory = tadisk.directory
case command
when "dir"
  if ARGV.empty?
    puts directory
  else
    wildcard = false
    ARGV.each do |filename|
      if filename == "*"
        directory.each do |entry|
          file = TaFile.new entry
          puts file
        end
      else
        entry = directory.find filename
        if entry.nil?
          STDERR.puts "File #{filename.inspect} not found"
          exit 1
        else
          file = TaFile.new entry
          puts file
        end
      end
    end
  end
when "copy"
  if ARGV.empty?
    usage "Missing filename after 'copy'"
  end
  ARGV.each do |filename|
    if filename == "*"
      directory.each do |entry|
        file = TaFile.new entry
        puts file.name
        file.copy file.name
      end
    else
      entry = directory.find filename
      if entry.nil?
        STDERR.puts "File #{filename.inspect} not found"
        exit 1
      else
        file = TaFile.new entry
        puts file.name
        file.copy filename
      end
    end  
  end
else
  usage "Unknown command #{command.inspect}"
end
