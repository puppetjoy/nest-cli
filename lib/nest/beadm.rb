# frozen_string_literal: true

require 'shellwords'

module Nest
  # Manage ZFS boot environments
  class Beadm
    include Nest::CLI

    ZFS_ADMIN   = Process.uid.zero? ? 'zfs' : 'sudo zfs'
    ZPOOL_ADMIN = Process.uid.zero? ? 'zpool' : 'sudo zpool'

    def initialize
      @current_fs = %x(zfs list -H -o name `findmnt -n -o SOURCE /`).chomp
      raise '/ is not a ZFS boot environment' unless @current_fs =~ %r{^(([^/]+).*/ROOT)/([^/]+)$}

      @be_root = Regexp.last_match(1)
      @zpool = Regexp.last_match(2)
      @current_be = Regexp.last_match(3)
    end

    def list
      `zfs list -H -o name -r #{@be_root}`.lines.reduce([]) do |bes, filesystem|
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
      bootfs = `zpool get -H -o value bootfs #{@zpool}`.chomp
      raise 'zpool bootfs does not look like a boot environment' \
        unless bootfs =~ %r{^#{Regexp.escape(@be_root)}/([^/]+)$}

      Regexp.last_match(1)
    end

    def create(name)
      if name !~ /^[a-zA-Z0-9][a-zA-Z0-9_:.-]*$/
        logger.fatal "'#{name}' is not a valid boot environment name"
        return false
      end

      if list.include? name
        logger.fatal "Boot environment '#{name}' already exists"
        return false
      end

      logger.info "Creating boot environment '#{name}' from '#{current}'"

      snapshot = "beadm-clone-#{current}-to-#{name}"
      raise 'Failed to create snapshots for cloning' \
        unless cmd.run!("#{ZFS_ADMIN} snapshot -r #{@current_fs}@#{snapshot}").success?

      `zfs list -H -o name,mountpoint -r #{@current_fs}`.lines.each do |line|
        (fs, mp) = line.chomp.split("\t", 2)
        clone_fs = "#{@be_root}/#{name}#{fs.sub(/^#{Regexp.escape(@current_fs)}/, '')}"
        clone_cmd = "#{ZFS_ADMIN} clone -o canmount=noauto -o mountpoint=#{mp.shellescape} " \
                    "#{fs}@#{snapshot} #{clone_fs}"
        if cmd.run!(clone_cmd).failure?
          cmd.run! "#{ZFS_ADMIN} destroy -R #{@current_fs}@#{snapshot}"
          raise 'Failed to clone snapshot. Manual cleanup may be requried.'
        end
      end

      logger.success "Created boot environment '#{name}'"
      true
    end

    def destroy(name)
      if name == current
        logger.fatal 'Cannot destroy the active boot environment'
        return false
      end

      destroy_be = "#{@be_root}/#{name}"

      unless system "zfs list #{destroy_be.shellescape} > /dev/null 2>&1"
        logger.fatal "Boot environment '#{name}' does not exist"
        return false
      end

      logger.info "Destroying boot environment '#{name}'"

      raise 'Failed to destroy the boot environment' \
        unless cmd.run!("#{ZFS_ADMIN} destroy -r #{destroy_be}").success?

      `zfs list -H -o name -t snapshot -r #{@be_root}`.lines.map(&:chomp).each do |snapshot|
        next unless snapshot =~ /@beadm-clone-(#{Regexp.escape(name)}-to-.*|.*-to-#{Regexp.escape(name)})$/
        raise 'Failed to destroy snapshot. Manual cleanup may be required.' \
          unless cmd.run!("#{ZFS_ADMIN} destroy #{snapshot}").success?
      end

      logger.warn "/mnt/#{name} exists and couldn't be removed" \
        if Dir.exist?("/mnt/#{name}") && cmd.run!("sudo rmdir /mnt/#{name}").failure?

      logger.success "Destroyed boot environment '#{name}'"
      true
    end

    def mount(name)
      mount_be = "#{@be_root}/#{name}"

      zfs_list = `zfs list -H -o name,mountpoint -r #{mount_be.shellescape} 2>/dev/null`.lines
      filesystems = zfs_list.each_with_object({}) do |line, fss|
        (fs, mountpoint) = line.chomp.split("\t", 2)
        mountpoint = '' if mountpoint == '/'
        fss[fs] = "/mnt/#{name}#{mountpoint}"
        fss
      end

      if filesystems.empty?
        logger.fatal "Boot environment '#{name}' does not exist"
        return false
      end

      mounted = `zfs mount`.lines.each_with_object({}) do |line, m|
        (fs, mountpoint) = line.chomp.split(' ', 2)
        m[fs] = mountpoint
        m
      end

      if (filesystems.to_a & mounted.to_a).to_h == filesystems
        logger.warn "The boot environment is already mounted at /mnt/#{name}"
        return true
      end

      unless (filesystems.keys & mounted.keys).empty?
        logger.fatal 'The boot environment is already mounted'
        return false
      end

      logger.info "Mounting boot environment '#{name}' at /mnt/#{name}"

      raise "Failed to make /mnt/#{name}" \
        unless Dir.exist?("/mnt/#{name}") || cmd.run!("sudo mkdir /mnt/#{name}").success?

      filesystems.each do |fs, mountpoint|
        next if cmd.run!("sudo mount -t zfs -o zfsutil #{fs} #{mountpoint}").success?

        cmd.run! "sudo umount -R /mnt/#{name}"
        cmd.run! "sudo rmdir /mnt/#{name}"
        raise 'Failed to mount the boot environment. Manual cleanup may be required.'
      end

      logger.success "Mounted boot environment '#{name}' at /mnt/#{name}"
      true
    end

    def unmount(name)
      unmount_be = "#{@be_root}/#{name}"

      zfs_list = `zfs list -H -o name,mountpoint -r #{unmount_be.shellescape} 2>/dev/null`.lines
      filesystems = zfs_list.each_with_object({}) do |line, fss|
        (fs, mountpoint) = line.chomp.split("\t", 2)
        mountpoint = '' if mountpoint == '/'
        fss[fs] = "/mnt/#{name}#{mountpoint}"
        fss
      end

      if filesystems.empty?
        logger.fatal "Boot environment '#{name}' does not exist"
        return false
      end

      mounted = `zfs mount`.lines.each_with_object({}) do |line, m|
        (fs, mountpoint) = line.chomp.split(' ', 2)
        m[fs] = mountpoint
        m
      end

      if (filesystems.to_a & mounted.to_a).empty?
        logger.warn 'The boot environment is already unmounted'
        return true
      end

      logger.info "Unmounting boot environment '#{name}'"

      if cmd.run!("sudo umount -R /mnt/#{name}").failure? || cmd.run!("sudo rmdir /mnt/#{name}").failure?
        logger.error 'Failed to unmount the boot environment. Is something using it?'
        return false
      end

      logger.success "Unmounted boot environment '#{name}'"
      true
    end

    def activate(name = nil)
      if name
        unless list.include? name
          logger.fatal "Boot environment '#{name}' does not exist"
          return false
        end

        logger.info "Configuring boot environment '#{name}' for next reboot"

        raise 'Failed to set zpool \'bootfs\' property' \
          unless name == active || cmd.run!("#{ZPOOL_ADMIN} set bootfs=#{@be_root}/#{name} #{@zpool}").success?

        logger.success "Boot environment '#{name}' will be active next reboot"
      end

      logger.info "Activating current boot environment '#{@current_fs.sub(%r{.*/}, '')}'"

      `zfs list -H -o name,canmount,origin -r #{@be_root}`.lines.each do |line|
        (fs, canmount, origin) = line.chomp.split("\t", 3)

        if fs =~ %r{^#{Regexp.escape(@current_fs)}($|/)}
          raise 'Failed to enable active boot environment' \
            unless canmount == 'on' || cmd.run!("#{ZFS_ADMIN} set canmount=on #{fs}").success?

          raise 'Failed to promote active boot environment clone' \
            unless origin == '-' || cmd.run!("#{ZFS_ADMIN} promote #{fs}").success?
        else
          raise 'Failed to disable inactive boot environment' \
            unless canmount == 'noauto' || cmd.run!("#{ZFS_ADMIN} set canmount=noauto #{fs}")
        end
      end

      logger.success "Boot environment '#{@current_fs.sub(%r{.*/}, '')}' is active"
    end
  end
end
