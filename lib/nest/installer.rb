# frozen_string_literal: true

require 'stringio'

module Nest
  # Install hosts from scratch and update existing ones
  class Installer
    include Nest::CLI

    attr_reader :name, :image, :platform, :role, :boot, :disk, :force

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
      when 'live'
        require_relative 'installer/live'
        Nest::Installer::Live.new(name, image, platform, role)
      when 'milkv-pioneer'
        require_relative 'installer/milkvpioneer'
        Nest::Installer::MilkvPioneer.new(name, image, platform, role)
      when 'pine64', 'sopine'
        require_relative 'installer/pine64'
        Nest::Installer::Pine64.new(name, image, platform, role)
      when 'radxazero'
        require_relative 'installer/radxazero'
        Nest::Installer::RadxaZero.new(name, image, platform, role)
      when /raspberrypi\d*/
        require_relative 'installer/raspberrypi'
        Nest::Installer::RaspberryPi.new(name, image, platform, role)
      when 'pinebookpro', 'rockpro64', 'rock4'
        require_relative 'installer/rk3399'
        Nest::Installer::RK3399.new(name, image, platform, role)
      when 'rock5'
        require_relative 'installer/rock5'
        Nest::Installer::Rock5.new(name, image, platform, role)
      when 'haswell', 'vmware', 'vmware-fusion'
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

    def install(boot, disk, encrypt, force, start = :partition, stop = :firmware, ashift = 9, supports_encryption: true)
      @boot = boot
      @disk = disk
      @force = force

      format_options = { ashift: ashift, fscache_size: fscache_size(disk) }

      steps = {
        partition: -> { partition },
        format: -> { format(**format_options) },
        mount: -> { mount },
        copy: -> { copy },
        bootloader: -> { bootloader },
        unmount: -> { unmount },
        firmware: -> { firmware },
        cleanup: -> { cleanup }
      }

      unless steps[start]
        logger.error "'#{start}' is not a valid step"
        return false
      end

      unless steps[stop]
        logger.error "'#{stop}' is not a valid step"
        return false
      end

      if encrypt && !supports_encryption
        logger.error "Platform '#{platform}' does not support encryption"
        return false
      end

      if whole_disk? && !boot
        logger.error 'Whole disk zpools are only supported with a boot disk'
        return false
      end

      if steps.keys.index(start) <= steps.keys.index(:mount) && encrypt
        passphrase = prompt.mask('Encryption passphrase:')
        if passphrase && passphrase.length < 8
          logger.error 'Passphrase must be at least 8 characters long'
          return false
        end
        if steps.keys.index(start) <= steps.keys.index(:format)
          if passphrase
            if prompt.mask('Encryption passphrase (again):') != passphrase
              logger.error 'Passphrases do not match'
              return false
            end
            steps[:format] = -> { format(**format_options, passphrase: passphrase) }
          else
            passphrase = File.read("#{image}/etc/machine-id").chomp
            steps[:format] = lambda do
              format(**format_options, keylocation: 'file:///etc/machine-id',
                                       passphrase: passphrase)
            end
          end
        end
        steps[:mount] = -> { mount(passphrase) }
      end

      steps.values[(steps.keys.index start)..(steps.keys.index stop)].drop_while(&:call).empty?
    end

    def partition(gpt_table_length: nil)
      return false unless devices_ready?

      script = StringIO.new
      script.puts 'label: gpt'
      script.puts "table-length: #{gpt_table_length}" if gpt_table_length
      if boot_fstype == 'vfat'
        # Let sfdisk pick an aligned start sector for the ESP.
        script.puts "size=512MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=\"#{name}-boot\""
      else
        # BIOS + /boot case, still letting sfdisk choose starts.
        script.puts "size=30720, type=21686148-6449-6E6F-744E-656564454649, name=\"#{name}-bios\""
        script.puts "size=512MiB, type=BC13C2FF-59E6-4262-A352-B275FD6F7172, name=\"#{name}-boot\""
      end

      if boot
        logger.info "Partitioning #{boot}"
        return false unless sfdisk(boot, script)

        logger.success "#{boot} is partitioned"

        unless whole_disk?
          script = StringIO.new
          script.puts 'label: gpt'
        end
      end

      unless whole_disk?
        script.puts "name=\"#{name}\""

        logger.info "Partitioning #{boot}"
        return false unless sfdisk(disk, script)

        logger.success "#{disk} is partitioned"
      end

      cmd.run 'udevadm settle'
    end

    def format(ashift: 9, keylocation: nil, passphrase: nil, fscache_size: '2G', swap_size: '4G')
      return false unless devices_ready?

      vdev = whole_disk? ? disk : name
      zroot = passphrase ? "#{name}/crypt" : name

      logger.info "Creating ZFS pool '#{name}'"
      cmd.run ADMIN + "zpool create -f -m none -o ashift=#{ashift} " \
                      '-O compression=lz4 -O xattr=sa -O acltype=posixacl ' \
                      "-R #{target} #{name} #{vdev}"
      if passphrase
        cmd.run(ADMIN + "zfs create -o encryption=aes-128-gcm -o keyformat=passphrase -o keylocation=prompt #{zroot}",
                input: passphrase)
        cmd.run(ADMIN + "zfs set keylocation=#{keylocation} #{zroot}") if keylocation
      end
      cmd.run ADMIN + "zfs create -o atime=off #{zroot}/ROOT"
      cmd.run ADMIN + "zfs create -o mountpoint=/ #{zroot}/ROOT/A"
      cmd.run ADMIN + "zfs create -o mountpoint=/var #{zroot}/ROOT/A/var"
      cmd.run ADMIN + "zfs create -o mountpoint=/usr/lib/debug -o compression=zstd #{zroot}/ROOT/A/debug"
      cmd.run ADMIN + "zfs create -o mountpoint=/usr/src -o compression=zstd #{zroot}/ROOT/A/src"
      cmd.run ADMIN + "zfs create -o mountpoint=/home #{zroot}/home"
      cmd.run ADMIN + "zfs create #{zroot}/home/joy"
      cmd.run ADMIN + "zpool set bootfs=#{zroot}/ROOT/A #{name}"
      logger.success "Created ZFS pool '#{name}'"

      logger.info 'Creating swap space'
      cmd.run ADMIN + "zfs create -V #{swap_size} -b 4096 -o refreservation=none #{zroot}/swap"
      cmd.run 'udevadm settle'
      cmd.run ADMIN + "mkswap -L #{labelname}-swap /dev/zvol/#{zroot}/swap"
      logger.success 'Created swap space'

      unless File.open("#{image}/etc/fstab").grep(/#{labelname}-fscache/).empty?
        logger.info 'Creating fscache'
        cmd.run ADMIN + "zfs create -V #{fscache_size} #{zroot}/fscache"
        cmd.run 'udevadm settle'
        cmd.run ADMIN + "mkfs.ext4 -q -L #{labelname}-fscache /dev/zvol/#{zroot}/fscache"
        cmd.run ADMIN + "tune2fs -o discard /dev/zvol/#{zroot}/fscache"
        logger.success 'Created fscache'
      end

      logger.info 'Creating boot filesystem'
      if boot_fstype == 'vfat'
        cmd.run ADMIN + "mkfs.vfat -n #{labelname}-bt #{boot_device}" # label <= 11 chars for FAT32
      else
        cmd.run ADMIN + "mkfs.#{boot_fstype} #{boot_device}"
      end
      logger.success 'Created boot filesystem'
    end

    def mount(passphrase = nil)
      logger.info 'Mounting filesystems'

      if zpool_mounted?
        logger.info "ZFS pool '#{name}' is already mounted"
      else
        if zpool_imported?
          if force
            logger.warn "Exporting ZFS pool '#{name}' to reimport it at #{target}"
            cmd.run ADMIN + "zpool export #{name}"
          else
            logger.error "ZFS pool '#{name}' is imported but not mounted to #{target}"
            logger.error "Export the pool or use '--force' to continue"
            return false
          end
        end

        logger.info 'Importing ZFS pool'
        cmd.run ADMIN + "zpool import -f -R #{target} #{name}"
        cmd.run(ADMIN + "zfs load-key -r -L prompt #{name}/crypt", input: passphrase) if passphrase
        cmd.run ADMIN + 'zfs mount -al' # rubocop:disable Style/StringConcatenation
        logger.success 'Imported ZFS pool'
      end

      unless $DRY_RUN || ensure_target_mounted
        logger.error "Nothing is mounted at #{target}"
        logger.error 'Is the ZFS pool encrypted?'
        return false
      end

      if device_mounted?(boot_device, at: boot_dir)
        logger.info 'Boot device is already mounted'
      else
        return false unless ensure_boot_device_unmounted

        logger.info 'Mounting boot device'
        cmd.run(ADMIN + "mkdir #{boot_dir}") unless Dir.exist? boot_dir
        cmd.run ADMIN + "mount #{boot_device} #{target}/boot"
        logger.success 'Mounted boot device'
      end

      logger.success 'Filesystems mounted'
    end

    def copy
      return false unless $DRY_RUN || ensure_target_mounted

      logger.info 'Copying image'
      cmd.run(ADMIN + "rsync -aAHX --delete --info=progress2 root@falcon:#{image}/ #{target}",
              out: '/dev/stdout', err: '/dev/stderr')
      logger.success 'Copied image'
    end

    def bootloader
      return false unless $DRY_RUN || ensure_target_mounted

      logger.info 'Installing bootloader'
      puppet_cmd = 'puppet agent --test --tags boot'
      puppet_status = nspawn(target, puppet_cmd, directout: true)
      unless [0, 2].include? puppet_status
        logger.error 'Puppet run to install bootloader failed'
        return false
      end
      logger.success 'Installed bootloader'
    end

    def unmount
      logger.info 'Unmounting filesystems'
      cmd.run ADMIN + "umount -R #{target}" if target_mounted?
      cmd.run(ADMIN + "zpool export #{name}") if zpool_imported?
      cmd.run(ADMIN + "rmdir #{target}") if Dir.exist? target
      logger.success 'Filesystems unmounted'
    end

    def firmware
      true
    end

    def cleanup
      logger.info 'Cleaning up'
      unmount
      logger.success 'All clean!'
    end

    protected

    def ensure_device_unmounted(device, description)
      if device_mounted? device
        if force
          logger.warn "Unmounting #{description}"
          cmd.run ADMIN + "umount #{device}"
        else
          logger.error "Existing #{description} is mounted"
          logger.error "Unmount it or use '--force' to continue"
          return false
        end
      end
      true
    end

    def ensure_target_mounted
      unless target_mounted?
        logger.error "#{target} is not mounted"
        return false
      end
      true
    end

    def fscache_size(disk)
      size = `lsblk -bdno SIZE #{disk} 2>/dev/null`.to_i
      if size.positive?
        #        size < 5    => 1G
        #   5 <= size < 50   => 2G
        #  50 <= size < 500  => 4G
        # 500 <= size < 5000 => 8G
        "#{2**((size >> 29).to_s.length - 1)}G"
      else
        '2G'
      end
    end

    def labelname
      name.length > 8 && name =~ /^(\D{,8}).*?(\d*)$/ ? $1[0..-$2.length - 1] + $2 : name # rubocop:disable Style/PerlBackrefs
    end

    def target
      "/mnt/#{name}"
    end

    def boot_dir
      "#{target}/boot"
    end

    def make_hybrid_mbr(disk)
      logger.warn 'Making the hybrid MBR!'
      logger.warn 'See: https://gitlab.james.tl/nest/puppet/-/wikis/Platforms/Raspberry-Pi#hybrid-mbr'
      cmd.run ADMIN + "gdisk #{disk}", in: "r\nh\n1\nn\n0c\nn\nn\nw\ny\n"
      cmd.run 'udevadm settle'
    end

    private

    def sfdisk(disk, script)
      cmd.run!(ADMIN + "wipefs -a #{disk}").success? or
        logger.warn "Failed to wipe signatures from #{disk}"

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

      true
    end

    def boot_device
      "/dev/disk/by-partlabel/#{name}-boot"
    end

    def boot_fstype
      `awk '/^(PART)?LABEL=(#{name}-boot|#{labelname}-bt)\\s/ { print $3 }' #{image}/etc/fstab`.chomp
    end

    def ensure_boot_device_unmounted
      ensure_device_unmounted(boot_device, 'boot device')
    end

    def device_mounted?(device, at: nil)
      device = File.realpath(device) if File.exist?(device)
      if at
        `mount`.match?(/^#{device} on #{at}\s/)
      else
        `mount`.match?(/^#{device}\s/)
      end
    end

    def devices_ready?
      ensure_boot_device_unmounted & zpool_absent?
    end

    def target_mounted?
      system "mountpoint -q #{target}"
    end

    def whole_disk?
      disk !~ %r{^/}
    end

    def zpool_absent?
      if zpool_imported?
        if force
          logger.warn "Destroying existing ZFS pool '#{name}'"
          cmd.run ADMIN + "zpool destroy #{name}"
        else
          logger.error "ZFS pool '#{name}' already exists"
          logger.error "Destroy it or use '--force' to continue"
          return false
        end
      end
      true
    end

    def zpool_imported?
      system "zpool list #{name} > /dev/null 2>&1"
    end

    def zpool_mounted?
      return false unless zpool_imported?

      altroot = `zpool get -H -o value altroot #{name}`.chomp
      altroot == target
    end
  end
end
