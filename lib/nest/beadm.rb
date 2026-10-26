# frozen_string_literal: true

require 'shellwords'
require 'open3'
require_relative 'command_failure'

module Nest
  # Manage ZFS boot environments
  class Beadm
    include Nest::CLI

    attr_reader :failure_exit_status

    def initialize
      roots = read_command('findmnt', '-rn', '-o', 'SOURCE', '--mountpoint', '/').lines.map(&:chomp)
      raise 'Expected exactly one mounted root; inspect stacked mounts before using beadm' unless roots.size == 1

      @current_fs = read_command('zfs', 'list', '-H', '-o', 'name', roots.first).chomp
      @current_fs =~ %r{\A(([^/\s]+)(?:/[^/\s]+)*/ROOT)/([^/\s]+)\z} or raise '/ is not a ZFS boot environment'
      @be_root = Regexp.last_match(1)
      @zpool = Regexp.last_match(2)
      @current_be = Regexp.last_match(3)
    end

    def list
      read_command('zfs', 'list', '-H', '-o', 'name', '-r', @be_root).lines.reduce([]) do |bes, filesystem|
        if filesystem.chomp =~ %r{^#{Regexp.escape(@be_root)}/([^/]+)$}
          bes << Regexp.last_match(1)
        else
          bes
        end
      end
    end

    def current
      @current_be
    end

    def active
      bootfs = read_command('zpool', 'get', '-H', '-o', 'value', 'bootfs', @zpool).chomp
      bootfs =~ %r{^#{Regexp.escape(@be_root)}/([^/]+)$} or raise 'zpool bootfs does not look like a boot environment'
      Regexp.last_match(1)
    end

    def create(name, snapshot: nil)
      if snapshot && !snapshot.match?(/\Anest-reset-[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/)
        raise 'Invalid transaction snapshot name'
      end

      if name !~ /^[a-zA-Z0-9][a-zA-Z0-9_:.-]*$/
        logger.error "'#{name}' is not a valid boot environment name"
        return false
      end

      if list.include? name
        logger.error "Boot environment '#{name}' already exists"
        return false
      end

      logger.info "Creating boot environment '#{name}' from '#{current}'"

      transaction_owned = !snapshot.nil?
      snapshot ||= "beadm-clone-#{current}-to-#{name}"
      checked_command(ADMIN + "zfs snapshot -r #{@current_fs}@#{snapshot}").success? or
        raise 'Failed to create snapshots for cloning'

      read_command('zfs', 'list', '-H', '-o', 'name,compression,mountpoint', '-r', @current_fs).lines.each do |line|
        (fs, compression, mp) = line.chomp.split("\t", 3)
        clone_fs = "#{@be_root}/#{name}#{fs.sub(/^#{Regexp.escape(@current_fs)}/, '')}"
        clone_cmd = ADMIN + "zfs clone -o canmount=noauto -o compression=#{compression} " \
                            "-o mountpoint=#{mp.shellescape} #{fs}@#{snapshot} #{clone_fs}"
        next unless checked_command(clone_cmd).failure?

        # Native transactions retain partial creation for observation. A lost
        # or failed backup receipt must never cause a destructive retry.
        cmd.run! ADMIN + "zfs destroy -R #{@current_fs}@#{snapshot}" unless transaction_owned
        raise 'Failed to clone snapshot. Manual cleanup may be required.'
      end

      logger.success "Created boot environment '#{name}'"
      true
    end

    def destroy(name, reselect_next: false)
      if name == current
        logger.error 'Cannot destroy the current boot environment'
        return false
      end

      unless list.include? name
        logger.error "Boot environment '#{name}' does not exist"
        return false
      end

      if name == active
        unless reselect_next
          logger.error 'Cannot destroy the next-boot environment; explicitly select a safe boot environment first'
          return false
        end
        logger.warn 'Destroying the boot environment set to be active next boot'
        return false unless activate(current)
      end

      return false unless unmount(name)

      logger.info "Destroying boot environment '#{name}'"

      checked_command(ADMIN + "zfs destroy -r #{@be_root}/#{name}").success? or
        raise 'Failed to destroy the boot environment'

      # External clone origins may be shared or renamed. Names do not prove
      # ownership or retirement eligibility; retain them for explicit policy.

      (!Dir.exist?("/mnt/#{name}") || cmd.run!(ADMIN + "rmdir /mnt/#{name}").success?) or
        logger.warn "/mnt/#{name} exists and couldn't be removed"

      logger.success "Destroyed boot environment '#{name}'"
      true
    end

    def mount(name)
      mount_be = "#{@be_root}/#{name}"

      zfs_list = read_command('zfs', 'list', '-H', '-o', 'name,mountpoint', '-r', mount_be).lines
      filesystems = zfs_list.each_with_object({}) do |line, fss|
        (fs, mountpoint) = line.chomp.split("\t", 2)
        mountpoint = '' if mountpoint == '/'
        fss[fs] = "/mnt/#{name}#{mountpoint}"
        fss
      end

      if filesystems.empty?
        logger.error "Boot environment '#{name}' does not exist"
        return false
      end

      mounted = read_command('zfs', 'mount').lines.each_with_object({}) do |line, m|
        (fs, mountpoint) = line.chomp.split(' ', 2)
        m[fs] = mountpoint
        m
      end

      if (filesystems.to_a & mounted.to_a).to_h == filesystems
        logger.warn "The boot environment is already mounted at /mnt/#{name}"
        return :mounted
      end

      unless (filesystems.keys & mounted.keys).empty?
        logger.error 'The boot environment is already mounted'
        return false
      end

      logger.info "Mounting boot environment '#{name}' at /mnt/#{name}"

      (Dir.exist?("/mnt/#{name}") || checked_command(ADMIN + "mkdir /mnt/#{name}").success?) or
        raise "Failed to make /mnt/#{name}"

      filesystems.each do |fs, mountpoint|
        next if checked_command(ADMIN + "mount -t zfs -o zfsutil #{fs} #{mountpoint}").success?

        cmd.run! ADMIN + "umount -R /mnt/#{name}"
        cmd.run! ADMIN + "rmdir /mnt/#{name}"
        raise 'Failed to mount the boot environment. Manual cleanup may be required.'
      end

      checked_command(ADMIN + "mount --bind /boot /mnt/#{name}/boot").success? or
        raise 'Failed to bind mount /boot'

      logger.success "Mounted boot environment '#{name}' at /mnt/#{name}"
      true
    end

    def unmount(name)
      unmount_be = "#{@be_root}/#{name}"

      zfs_list = read_command('zfs', 'list', '-H', '-o', 'name,mountpoint', '-r', unmount_be).lines
      filesystems = zfs_list.each_with_object({}) do |line, fss|
        (fs, mountpoint) = line.chomp.split("\t", 2)
        mountpoint = '' if mountpoint == '/'
        fss[fs] = "/mnt/#{name}#{mountpoint}"
        fss
      end

      if filesystems.empty?
        logger.error "Boot environment '#{name}' does not exist"
        return false
      end

      mounted = read_command('zfs', 'mount').lines.each_with_object({}) do |line, m|
        (fs, mountpoint) = line.chomp.split(' ', 2)
        m[fs] = mountpoint
        m
      end

      unless (filesystems.keys & mounted.keys).all? { |fs| filesystems[fs] == mounted[fs] }
        raise 'Boot environment is mounted outside its expected /mnt path; refusing to unmount'
      end

      if (filesystems.keys & mounted.keys).empty?
        logger.info 'The boot environment is already unmounted'
        return true
      end

      logger.info "Unmounting boot environment '#{name}'"

      if checked_command(ADMIN + "umount -R /mnt/#{name}").failure? ||
         checked_command(ADMIN + "rmdir /mnt/#{name}").failure?
        logger.error 'Failed to unmount the boot environment. Is something using it?'
        return false
      end

      logger.success "Unmounted boot environment '#{name}'"
      true
    end

    def activate(name = nil)
      if name
        unless list.include? name
          logger.error "Boot environment '#{name}' does not exist"
          return false
        end

        logger.info "Configuring boot environment '#{name}' for next reboot"

        trees = activation_filesystems
        disable_inactive(trees)
        # Perform the real accounting transfer before selecting the next boot.
        # Payload size and pool free space do not predict promotion quota use.
        promote_tree(trees, "#{@be_root}/#{name}")

        (name == active || checked_command(ADMIN + "zpool set bootfs=#{@be_root}/#{name} #{@zpool}").success?) or
          raise 'Failed to set zpool \'bootfs\' property'

        logger.success "Boot environment '#{name}' will be active next reboot"
      else
        logger.info "Activating current boot environment '#{@current_fs.sub(%r{.*/}, '')}'"

        trees = activation_filesystems
        # zfs-mount.service may continue even if this command fails. Establish
        # mount safety for ALL trees before enabling or promoting any dataset.
        disable_inactive(trees)
        trees.each do |fs, canmount, _origin|
          next unless in_tree?(fs, @current_fs) && canmount == 'noauto'

          checked_command(ADMIN + "zfs set canmount=on #{fs.shellescape}").success? or
            raise "Failed to enable active boot environment dataset #{fs}"
        end
        promote_tree(trees, @current_fs)

        logger.success "Boot environment '#{@current_fs.sub(%r{.*/}, '')}' is active"
      end
      true
    end

    private

    def checked_command(command)
      result = cmd.run!(command)
      @failure_exit_status ||= result.exit_status if result.failure?
      result
    end

    def read_command(*args)
      output, status = Open3.capture2e(*args)
      unless status.success?
        @failure_exit_status ||= status.exitstatus
        raise CommandFailure.new("read #{args.first}: #{output.strip}", status.exitstatus)
      end

      output
    end

    def in_tree?(filesystem, tree)
      filesystem == tree || filesystem.start_with?("#{tree}/")
    end

    def activation_filesystems
      rows = read_command('zfs', 'list', '-H', '-t', 'filesystem', '-o', 'name,canmount,origin',
                          '-r', @be_root).lines.map { |line| line.chomp.split("\t", 3) }
      valid = rows.all? do |fs, canmount, origin|
        fs && in_tree?(fs, @be_root) && %w[on off noauto].include?(canmount) && origin
      end
      (valid && rows.any? { |fs, _canmount, _origin| fs == @current_fs }) or
        raise 'Invalid or incomplete boot environment filesystem inventory'

      rows
    end

    def disable_inactive(trees)
      failed = trees.each_with_object([]) do |(fs, canmount, _origin), errors|
        next if in_tree?(fs, @current_fs) || %w[off noauto].include?(canmount)
        next if checked_command(ADMIN + "zfs set canmount=noauto #{fs.shellescape}").success?

        errors << fs
      rescue StandardError => e
        errors << "#{fs} (#{e.message})"
      end
      return if failed.empty?

      raise "Failed to disable inactive boot environment datasets: #{failed.join(', ')}; do not run zfs mount -a"
    end

    def promote_tree(trees, tree)
      raise "Boot environment dataset #{tree} is missing" unless trees.any? { |fs, _canmount, _origin| fs == tree }

      trees.each do |fs, _canmount, origin|
        next unless in_tree?(fs, tree) && origin != '-'
        next if checked_command(ADMIN + "zfs promote #{fs.shellescape}").success?

        raise "Failed to promote boot environment clone #{fs}; check quota and snapshot accounting before retrying"
      end
    end
  end
end
