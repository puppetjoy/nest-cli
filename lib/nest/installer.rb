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
      when 'milkv-mars'
        require_relative 'installer/milkv_mars'
        Nest::Installer::MilkvMars.new(name, image, platform, role)
      when 'milkv-pioneer'
        require_relative 'installer/milkv_pioneer'
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
      when 'strix-halo', 'vmware-fusion', 'wellsburg'
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

    def install(boot, disk, encrypt, force, start = :partition, stop = :firmware, ashift = 9,
                supports_encryption: true, installer: false)
      @boot = boot
      @disk = disk
      @force = force
      @installer = installer
      @encrypt = encrypt

      @use_ext4_root = ext4_root_in_image?

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

      if @installer && @use_ext4_root
        logger.error 'Installer images require ZFS root; ext4 root is unsupported with --installer'
        return false
      end

      if !@use_ext4_root && whole_disk? && !boot
        logger.error 'Whole disk zpools are only supported with a boot disk'
        return false
      end

      if steps.keys.index(start) <= steps.keys.index(:mount) && encrypt && !@use_ext4_root
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

    def partition(pre_script: [], start: nil)
      return false unless devices_ready?

      script = StringIO.new
      script.puts 'label: gpt'

      # Let platforms define their own partitions and settings
      pre_script&.each { |line| script.puts line }

      start_prefix = start ? "start=#{start}, " : ''
      script.puts start_prefix + "size=512MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=\"#{name}-boot\""

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

      if @use_ext4_root
        logger.info 'Creating ext4 root filesystem'
        cmd.run ADMIN + "mkfs.ext4 -q -L #{labelname} #{root_device}"
        logger.success 'Created ext4 root filesystem'
      else
        vdev = whole_disk? ? disk : name
        zroot = passphrase ? "#{poolname}/crypt" : poolname

        logger.info "Creating ZFS pool '#{name}'"
        cmd.run ADMIN + "zpool create -f -m none -o ashift=#{ashift} " \
                        '-O compression=lz4 -O xattr=sa -O acltype=posixacl ' \
                        "-R #{target} #{poolname} #{vdev}"
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
        cmd.run ADMIN + "zpool set bootfs=#{zroot}/ROOT/A #{poolname}"
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
      end

      logger.info 'Creating boot filesystem'
      cmd.run ADMIN + "mkfs.vfat -n #{labelname}-bt #{boot_device}" # label <= 11 chars for FAT32
      logger.success 'Created boot filesystem'
    end

    def mount(passphrase = nil)
      logger.info 'Mounting filesystems'
      if @use_ext4_root
        if target_mounted?
          logger.info "Target '#{target}' is already mounted"
        else
          return false unless ensure_root_device_unmounted

          cmd.run(ADMIN + "mkdir -p #{target}") unless Dir.exist? target
          logger.info 'Mounting root device'
          cmd.run ADMIN + "mount #{root_device} #{target}"
          logger.success 'Mounted root device'
        end
      else
        if zpool_mounted?
          logger.info "ZFS pool '#{name}' is already mounted"
        else
          if zpool_imported?
            if force
              logger.warn "Exporting ZFS pool '#{name}' to reimport it at #{target}"
              cmd.run ADMIN + "zpool export #{poolname}"
            else
              logger.error "ZFS pool '#{name}' is imported but not mounted to #{target}"
              logger.error "Export the pool or use '--force' to continue"
              return false
            end
          end

          logger.info 'Importing ZFS pool'
          cmd.run ADMIN + "zpool import -f -R #{target} #{poolname}"
          cmd.run(ADMIN + "zfs load-key -r -L prompt #{poolname}/crypt", input: passphrase) if passphrase
          cmd.run ADMIN + 'zfs mount -al' # rubocop:disable Style/StringConcatenation
          logger.success 'Imported ZFS pool'
        end

        unless $DRY_RUN || ensure_target_mounted
          logger.error "Nothing is mounted at #{target}"
          logger.error 'Is the ZFS pool encrypted?'
          return false
        end
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
      cmd.run(ADMIN + "rsync -aAHX --delete-before --info=progress2 root@falcon:#{image}/ #{target}",
              out: '/dev/stdout', err: '/dev/stderr')
      logger.success 'Copied image'
    end

    def bootloader
      return false unless $DRY_RUN || ensure_target_mounted

      logger.info 'Installing bootloader'

      # Write rpool fact so Puppet can configure ZFS datasets appropriately
      if @installer
        facts_dir = File.join(target, 'etc/puppetlabs/facter/facts.d')
        cmd.run ADMIN + "mkdir -p #{facts_dir}"
        rpool_value = @encrypt ? "#{poolname}/crypt" : poolname
        cmd.run(ADMIN + "tee #{File.join(facts_dir, 'rpool.txt')}", in: "rpool=#{rpool_value}\n")
      end

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
      cmd.run(ADMIN + "zpool export #{poolname}") if zpool_imported?
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

    def boot_dir
      "#{target}/boot"
    end

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

    def ensure_root_device_unmounted
      ensure_device_unmounted(root_device, 'root device')
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

    # Generate a label name <= 8 characters from hostname, prioritizing suffix after dash.
    # Examples:
    #   kestrel-console => kconsole
    #   eagle-gui       => eaglegui
    #   falcon-gui12    => falgui12
    #   foobarbaz12     => foobar12
    #   short           => short
    def labelname
      return name if name.length <= 8

      # Extract trailing digits
      digits = name.match(/(\d+)$/)
      digit_suffix = digits ? digits[1] : ''
      base = digits ? name[0...-digit_suffix.length] : name

      # If there's a dash, prioritize the suffix after the last dash
      if base.include?('-')
        parts = base.split('-')
        prefix = parts[0]
        suffix = parts[1..-1].join('-')

        # Calculate how much space we have for the label
        available = 8 - digit_suffix.length
        return name if available <= 0

        # Try to fit as much of the suffix as possible, then prefix
        if suffix.length >= available
          # Use only suffix if it fills or exceeds available space
          suffix[0...available] + digit_suffix
        else
          # Use full suffix and as much prefix as fits
          prefix_len = available - suffix.length
          prefix[0...prefix_len] + suffix + digit_suffix
        end
      else
        # No dash: use old logic (prefix + digits)
        available = 8 - digit_suffix.length
        return name if available <= 0

        base[0...available] + digit_suffix
      end
    end

    def make_hybrid_mbr(disk)
      logger.warn 'Making the hybrid MBR!'
      logger.warn 'See: https://gitlab.joyfullee.me/nest/puppet/-/wikis/Platforms/Raspberry-Pi#hybrid-mbr'
      cmd.run ADMIN + "gdisk #{disk}", in: "r\nh\n1\nn\n0c\nn\nn\nw\ny\n"
      cmd.run 'udevadm settle'
    end

    def target
      "/mnt/#{name}"
    end

    private

    def boot_device
      "/dev/disk/by-partlabel/#{name}-boot"
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
      ensure_boot_device_unmounted & storage_ready?
    end

    def ensure_boot_device_unmounted
      ensure_device_unmounted(boot_device, 'boot device')
    end

    def ext4_root_in_image?
      begin
        File.foreach("#{image}/etc/fstab") do |line|
          next if line.strip.start_with?('#') || line.strip.empty?

          # fstab columns: fs_spec fs_file fs_vfstype fs_mntops fs_freq fs_passno
          cols = line.split(/\s+/)
          next unless cols.length >= 2

          fs_file = cols[1]
          return true if fs_file == '/'
        end
      rescue Errno::ENOENT
        raise "#{image}/etc/fstab not found; cannot determine root filesystem"
      end
      false
    end

    def poolname
      @installer ? "#{name}-installer" : name
    end

    def root_device
      "/dev/disk/by-partlabel/#{name}"
    end

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

    def storage_ready?
      if @use_ext4_root
        ensure_root_device_unmounted
      else
        zpool_absent?
      end
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
          logger.warn "Destroying existing ZFS pool '#{poolname}'"
          cmd.run ADMIN + "zpool destroy #{poolname}"
        else
          logger.error "ZFS pool '#{poolname}' already exists"
          logger.error "Destroy it or use '--force' to continue"
          return false
        end
      end
      true
    end

    def zpool_imported?
      system "zpool list #{poolname} > /dev/null 2>&1"
    end

    def zpool_mounted?
      return false unless zpool_imported?

      altroot = `zpool get -H -o value altroot #{poolname}`.chomp
      altroot == target
    end
  end
end
