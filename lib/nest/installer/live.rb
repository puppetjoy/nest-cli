# frozen_string_literal: true

require 'shellwords'
require 'socket'

module Nest
  class Installer
    # Platform installer overrides
    class Live < Installer
      IMAGE_SIZE = '32G'

      def install(*args)
        super(*args, supports_encryption: false)
      end

      def partition
        return false unless ensure_image_unmounted

        if File.exist? rootfs_zvol
          if @force
            logger.warn 'Forcing removal of existing image'
            cmd.run ADMIN + "zfs destroy -r #{rootfs_dataset}"
            cmd.run "rm -rf #{temp_dir}"
          else
            logger.error "Build image #{rootfs_dataset} already exists"
            logger.error "Remove it or use '--force' to continue"
            return false
          end
        end

        logger.info 'Creating live image'
        cmd.run ADMIN + "zfs create -V #{IMAGE_SIZE} -o volblocksize=4k #{rootfs_dataset}"
        logger.success 'Created live image'
      end

      def format(_options = {})
        return false unless ensure_image_unmounted

        logger.info 'Formatting live image'
        cmd.run ADMIN + "mkfs.ext4 -q #{rootfs_zvol}"
        cmd.run ADMIN + "tune2fs -o discard #{rootfs_zvol}"
        logger.success 'Formatted live image'
      end

      def mount
        if device_mounted?(rootfs_zvol, at: target)
          logger.info 'Live image is already mounted'
        else
          return false unless ensure_image_unmounted

          logger.info 'Mounting live image'
          cmd.run(ADMIN + "mkdir #{target}") unless Dir.exist? target
          cmd.run ADMIN + "mount #{rootfs_zvol} #{target}"
          logger.success 'Mounted live image'
        end
      end

      def bootloader
        return false unless super

        logger.info 'Copy bootloader for bootable image'
        cmd.run("mkdir -p #{finish_dir}/boot") unless Dir.exist? "#{finish_dir}/boot"
        cmd.run "cp -a #{target}/boot/* #{finish_dir}/boot"
        logger.success 'Copied bootloader for bootable image'
      end

      def firmware
        logger.info "Creating bootable image #{disk}"
        cmd.run "mkdir -p #{liveos_dir}"
        cmd.run "touch #{rootfs_img}"
        cmd.run ADMIN + "dd if=#{rootfs_zvol} of=#{rootfs_img} bs=1M status=progress"
        cmd.run("mkdir -p #{finish_dir}/LiveOS") unless Dir.exist? "#{finish_dir}/LiveOS"
        cmd.run("mksquashfs #{build_dir}/LiveOS/squashfs-root #{finish_dir}/LiveOS/squashfs.img -noappend",
                out: '/dev/stdout')
        cmd.run "grub-mkrescue --modules=part_gpt -o #{disk.shellescape} #{finish_dir} -- " \
                "-iso-level 3 -volid #{name.upcase}"
        logger.success "Created bootable image #{disk}"
      end

      def cleanup
        logger.info 'Cleaning up'
        unmount
        cmd.run ADMIN + "zfs destroy -r #{rootfs_dataset}"
        cmd.run("rm -rf #{temp_dir}") if Dir.exist? temp_dir
        logger.success 'All clean!'
      end

      protected

      def temp_dir
        "/var/tmp/nest-install-#{name}"
      end

      def build_dir
        "#{temp_dir}/build"
      end

      def finish_dir
        "#{temp_dir}/finish"
      end

      def liveos_dir
        "#{build_dir}/LiveOS/squashfs-root/LiveOS"
      end

      def rootfs_dataset
        "#{Socket.gethostname}/#{name}-rootfs"
      end

      def rootfs_img
        "#{liveos_dir}/rootfs.img"
      end

      def rootfs_zvol
        "/dev/zvol/#{rootfs_dataset}"
      end

      private

      def ensure_image_unmounted
        ensure_device_unmounted(rootfs_zvol, 'live image')
      end
    end
  end
end
