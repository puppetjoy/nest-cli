# frozen_string_literal: true

require 'stringio'

module Nest
  # Install hosts from scratch and update existing ones
  class Installer
    include Nest::CLI

    attr_reader :name, :image, :platform, :role

    def self.for_host(name)
      image = "/nest/hosts/#{name}"

      FileTest.symlink? "#{image}/etc/portage/make.profile" or
        raise "Stage 3 image at #{image} does not exist"

      File.readlink("#{image}/etc/portage/make.profile") =~ %r{/([^/]+)/([^/]+)$} or
        raise "#{image} does not contain a valid profile"

      platform = Regexp.last_match(1)
      role     = Regexp.last_match(2)

      case platform
      when 'beagleboneblack'
        require_relative 'installer/beagleboneblack'
        Nest::Installer::BeagleBoneBlack.new(name, image, platform, role)
      when 'pinebookpro'
        require_relative 'installer/pinebookpro'
        Nest::Installer::PinebookPro.new(name, image, platform, role)
      when 'live'
        require_relative 'installer/live'
        Nest::Installer::Live.new(name, image, platform, role)
      when 'raspberrypi'
        require_relative 'installer/raspberrypi'
        Nest::Installer::RaspberryPi.new(name, image, platform, role)
      when 'sopine'
        require_relative 'installer/sopine'
        Nest::Installer::Sopine.new(name, image, platform, role)
      when 'haswell'
        Nest::Installer.new(name, image, platform, role)
      else
        raise "Platform '#{platform}' is unsupported"
      end
    end

    def initialize(name, image, platform, role)
      @name = name
      @image = image
      @platform = platform
      @role = role
    end

    def install(disk, encrypt, force, start = :partition, supports_encryption: true)
      @force = force

      steps = {
        partition: -> { partition(disk) },
        format: -> { format },
        mount: -> { mount },
        copy: -> { copy },
        bootloader: -> { bootloader },
        firmware: -> { firmware(disk) }
      }

      unless steps[start]
        logger.error "'#{start}' is not a valid step"
        return false
      end

      if encrypt && !supports_encryption
        logger.error "Platform '#{platform}' does not support encryption"
        return false
      end

      if steps.keys.index(start) <= steps.keys.index(:mount) && encrypt
        passphrase = prompt.mask('Encryption passphrase:')
        if steps.keys.index(start) <= steps.keys.index(:format)
          if prompt.mask('Encryption passphrase (again):') != passphrase
            logger.error 'Passphrases do not match'
            return false
          end
          steps[:format] = -> { format(passphrase) }
        end
        steps[:mount] = -> { mount(passphrase) }
      end

      steps.values[(steps.keys.index start)..].drop_while(&:call).empty?
    end

    def partition(disk, gpt_table_length = nil)
      return false unless zpool_absent?

      logger.info "Partitioning #{disk}"

      cmd.run!(ADMIN + "wipefs -a #{disk}").success? or
        logger.warn "Failed to wipe signatures from #{disk}"

      script = StringIO.new
      script.puts 'label: gpt'
      script.puts "table-length: #{gpt_table_length}" if gpt_table_length
      if Dir.exist? '/sys/firmware/efi'
        script.puts "start=32768, size=512MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=\"#{name}-boot\""
      else
        script.puts "size=30720, type=21686148-6449-6E6F-744E-656564454649, name=\"#{name}-bios\""
        script.puts "size=512MiB, type=BC13C2FF-59E6-4262-A352-B275FD6F7172, name=\"#{name}-boot\""
      end
      script.puts "name=\"#{name}\""
      script.rewind

      script_debug = -> { script.each_line { |line| logger.debug 'sfdisk:', line.chomp } }
      if $DRY_RUN
        logger.log_at :debug do
          script_debug.call
        end
      else
        script_debug.call
      end
      script.rewind

      if cmd.run!(ADMIN + "sfdisk -q #{disk}", in: script).failure?
        logger.error "Failed to partition #{disk}"
        return false
      end

      cmd.run 'udevadm settle'

      logger.success "#{disk} is partitioned"
    end

    def format(passphrase = nil, swap_size = '4G')
      return false unless zpool_absent?

      zroot = passphrase ? "#{name}/crypt" : name

      logger.info "Creating ZFS pool '#{name}'"
      cmd.run ADMIN + 'zpool create -f -m none -o ashift=9 -O compression=lz4 ' \
                      "-O xattr=sa -O acltype=posixacl -R #{target} #{name} #{name}"
      if passphrase
        cmd.run(ADMIN + "zfs create -o encryption=aes-128-gcm -o keyformat=passphrase -o keylocation=prompt #{zroot}",
                input: passphrase)
      end
      cmd.run ADMIN + "zfs create #{zroot}/ROOT"
      cmd.run ADMIN + "zfs create -o mountpoint=/ #{zroot}/ROOT/A"
      cmd.run ADMIN + "zfs create -o mountpoint=/var #{zroot}/ROOT/A/var"
      cmd.run ADMIN + "zfs create -o mountpoint=/usr/lib/debug -o compression=zstd #{zroot}/ROOT/A/debug"
      cmd.run ADMIN + "zfs create -o mountpoint=/usr/src -o compression=zstd #{zroot}/ROOT/A/src"
      cmd.run ADMIN + "zfs create -o mountpoint=/home #{zroot}/home"
      cmd.run ADMIN + "zfs create #{zroot}/home/james"
      cmd.run ADMIN + "zpool set bootfs=#{zroot}/ROOT/A #{name}"
      logger.success "Created ZFS pool '#{name}'"

      logger.info 'Creating swap space'
      cmd.run ADMIN + "zfs create -V #{swap_size} -b 4096 -o refreservation=none #{zroot}/swap"
      cmd.run 'udevadm settle'
      cmd.run ADMIN + "mkswap -L #{labelname}-swap /dev/zvol/#{zroot}/swap"
      logger.success 'Created swap space'

      unless File.open("#{image}/etc/fstab").grep(/#{labelname}-fscache/).empty?
        logger.info 'Creating fscache'
        cmd.run ADMIN + "zfs create -V 2G #{zroot}/fscache"
        cmd.run 'udevadm settle'
        cmd.run ADMIN + "mkfs.ext4 -q -L #{labelname}-fscache /dev/zvol/#{zroot}/fscache"
        cmd.run ADMIN + "tune2fs -o discard /dev/zvol/#{zroot}/fscache"
        logger.success 'Created fscache'
      end

      logger.info 'Creating boot filesystem'
      cmd.run ADMIN + "mkfs.vfat /dev/disk/by-partlabel/#{name}-boot"
      logger.success 'Created boot filesystem'
    end

    def mount(_passphrase = nil)
      logger.warn 'Mount placeholder'
    end

    def copy
      logger.warn 'Copy placeholder'
    end

    def bootloader
      logger.warn 'Bootloader placeholder'
    end

    def firmware(_disk)
      logger.warn 'Firmware placeholder'
    end

    protected

    def zpool_absent?
      if system "zpool list #{name} > /dev/null 2>&1"
        if @force
          logger.warn "Destroying existing ZFS pool '#{name}'"
          cmd.run ADMIN + "zpool destroy #{name}"
        else
          logger.error "ZFS pool '#{name}' already exists. Destroy it to continue."
          return false
        end
      end
      true
    end

    def labelname
      name =~ /(\d*)$/
      suffix = Regexp.last_match(1)
      name[0..(7 - suffix.length)] + suffix
    end

    def target
      "/mnt/#{name}"
    end
  end
end
