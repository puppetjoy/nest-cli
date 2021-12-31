# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class Live < Installer
      IMAGE_SIZE = '20G'

      def install(*args)
        super(*args, supports_encryption: false)
      end

      def partition(_disk)
        return false unless ensure_image_unmounted

        if File.exist? rootfs_img
          if @force
            logger.warn 'Forcing removal of existing build tree'
            cmd.run "rm -rf #{build_dir}"
          else
            logger.error "Build tree at #{build_dir} already exists"
            logger.error "Remove it or use '--force' to continue"
            return false
          end
        end

        logger.info 'Creating live image structure'
        cmd.run "mkdir -p #{liveos_dir}"
        cmd.run "truncate -s #{IMAGE_SIZE} #{rootfs_img}"
        logger.success 'Created live image structure'
      end

      def format
        return false unless ensure_image_unmounted

        logger.info 'Formatting live image'
        cmd.run "mkfs.ext4 -q #{rootfs_img}"
        cmd.run "tune2fs -o discard #{rootfs_img}"
        logger.success 'Formatted live image'
      end

      def mount
        if device_mounted?(rootfs_img, at: target)
          logger.info 'Live image is already mounted'
        else
          return false unless ensure_image_unmounted

          logger.info 'Mounting live image'
          cmd.run(ADMIN + "mkdir #{target}") unless Dir.exist? target
          cmd.run ADMIN + "mount #{rootfs_img} #{target}"
          logger.success 'Mounted live image'
        end
      end

      def cleanup
        if Dir.exist? build_dir
          logger.info 'Cleaning up'
          cmd.run "rm -rf #{build_dir}"
        end
        super
      end

      protected

      def build_dir
        "/var/tmp/nest-install-#{name}"
      end

      def liveos_dir
        "#{build_dir}/LiveOS/squashfs-root/LiveOS"
      end

      def rootfs_img
        "#{liveos_dir}/rootfs.img"
      end

      private

      def ensure_image_unmounted
        ensure_device_unmounted(rootfs_img, 'live image')
      end
    end
  end
end
