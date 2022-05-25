# frozen_string_literal: true

require 'shellwords'

module Nest
  # Manage ZFS boot environments
  class Beadm
    include Nest::CLI

    def initialize
      @current_fs = %x(zfs list -H -o name `findmnt -n -o SOURCE /`).chomp
      @current_fs =~ %r{^(([^/]+).*/ROOT)/([^/]+)$} or raise '/ is not a ZFS boot environment'
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
      bootfs =~ %r{^#{Regexp.escape(@be_root)}/([^/]+)$} or raise 'zpool bootfs does not look like a boot environment'
      Regexp.last_match(1)
    end

    def create(name)
      if name !~ /^[a-zA-Z0-9][a-zA-Z0-9_:.-]*$/
        logger.error "'#{name}' is not a valid boot environment name"
        return false
      end

      if list.include? name
        logger.error "Boot environment '#{name}' already exists"
        return false
      end

      logger.info "Creating boot environment '#{name}' from '#{current}'"

      snapshot = "beadm-clone-#{current}-to-#{name}"
      cmd.run!(ADMIN + "zfs snapshot -r #{@current_fs}@#{snapshot}").success? or
        raise 'Failed to create snapshots for cloning'

      `zfs list -H -o name,compression,mountpoint -r #{@current_fs}`.lines.each do |line|
        (fs, compression, mp) = line.chomp.split("\t", 3)
        clone_fs = "#{@be_root}/#{name}#{fs.sub(/^#{Regexp.escape(@current_fs)}/, '')}"
        clone_cmd = ADMIN + "zfs clone -o canmount=noauto -o compression=#{compression} " \
                            "-o mountpoint=#{mp.shellescape} #{fs}@#{snapshot} #{clone_fs}"
        if cmd.run!(clone_cmd).failure?
          cmd.run! ADMIN + "zfs destroy -R #{@current_fs}@#{snapshot}"
          raise 'Failed to clone snapshot. Manual cleanup may be requried.'
        end
      end

      logger.success "Created boot environment '#{name}'"
      true
    end

    def destroy(name)
      if name == current
        logger.error 'Cannot destroy the current boot environment'
        return false
      end

      if name == active
        logger.error 'Cannot destroy the boot environment set to be active next boot'
        return false
      end

      unless list.include? name
        logger.error "Boot environment '#{name}' does not exist"
        return false
      end

      logger.info "Destroying boot environment '#{name}'"

      cmd.run!(ADMIN + "zfs destroy -r #{@be_root}/#{name}").success? or
        raise 'Failed to destroy the boot environment'

      `zfs list -H -o name -t snapshot -r #{@be_root}`.lines.map(&:chomp).each do |snapshot|
        next unless snapshot =~ /@beadm-clone-(#{Regexp.escape(name)}-to-.*|.*-to-#{Regexp.escape(name)})$/

        cmd.run!(ADMIN + "zfs destroy #{snapshot}").success? or
          raise 'Failed to destroy snapshot. Manual cleanup may be required.'
      end

      (!Dir.exist?("/mnt/#{name}") || cmd.run!(ADMIN + "rmdir /mnt/#{name}").success?) or
        logger.warn "/mnt/#{name} exists and couldn't be removed"

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
        logger.error "Boot environment '#{name}' does not exist"
        return false
      end

      mounted = `zfs mount`.lines.each_with_object({}) do |line, m|
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

      (Dir.exist?("/mnt/#{name}") || cmd.run!(ADMIN + "mkdir /mnt/#{name}").success?) or
        raise "Failed to make /mnt/#{name}"

      filesystems.each do |fs, mountpoint|
        next if cmd.run!(ADMIN + "mount -t zfs -o zfsutil #{fs} #{mountpoint}").success?

        cmd.run! ADMIN + "umount -R /mnt/#{name}"
        cmd.run! ADMIN + "rmdir /mnt/#{name}"
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
        logger.error "Boot environment '#{name}' does not exist"
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

      if cmd.run!(ADMIN + "umount -R /mnt/#{name}").failure? || cmd.run!(ADMIN + "rmdir /mnt/#{name}").failure?
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

        (name == active || cmd.run!(ADMIN + "zpool set bootfs=#{@be_root}/#{name} #{@zpool}").success?) or
          raise 'Failed to set zpool \'bootfs\' property'

        logger.success "Boot environment '#{name}' will be active next reboot"
      else
        logger.info "Activating current boot environment '#{@current_fs.sub(%r{.*/}, '')}'"

        `zfs list -H -o name,canmount,origin -r #{@be_root}`.lines.each do |line|
          (fs, canmount, origin) = line.chomp.split("\t", 3)

          if fs =~ %r{^#{Regexp.escape(@current_fs)}($|/)} # rubocop:disable Style/GuardClause
            (canmount == 'on' || cmd.run!(ADMIN + "zfs set canmount=on #{fs}").success?) or
              raise 'Failed to enable active boot environment'

            (origin == '-' || cmd.run!(ADMIN + "zfs promote #{fs}").success?) or
              raise 'Failed to promote active boot environment clone'
          else
            (canmount == 'noauto' || cmd.run!(ADMIN + "zfs set canmount=noauto #{fs}").success?) or
              raise 'Failed to disable inactive boot environment'
          end
        end

        logger.success "Boot environment '#{@current_fs.sub(%r{.*/}, '')}' is active"
      end
    end
  end
end
