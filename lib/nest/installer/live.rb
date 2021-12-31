# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class Live < Installer
      IMAGE_SIZE = '20G'

      def initialize(name, image, platform, role)
        super(name, image, platform, role)
      end

      def install(disk, encrypt, force, start = :partition)
        super(disk, encrypt, force, start, supports_encryption: false)
      end

      def partition(_disk)
        return false unless image_unmounted?

        if File.exist? rootfs_img
          if @force
            logger.warn 'Forcing removal of existing build tree'
            cmd.run "rm -rf #{build_dir}"
          else
            logger.error "Build tree at #{build_dir} already exists. Remove it to continue."
            return false
          end
        end

        logger.info 'Creating live image structure'
        cmd.run "mkdir -p #{liveos_dir}"
        cmd.run "truncate -s #{IMAGE_SIZE} #{rootfs_img}"
        logger.success 'Created live image structure'
      end

      def format
        return false unless image_unmounted?

        logger.info 'Formatting live image'
        cmd.run "mkfs.ext4 -q #{rootfs_img}"
        cmd.run "tune2fs -o discard #{rootfs_img}"
        logger.success 'Formatted live image'
      end

      protected

      def image_unmounted?
        if `mount` =~ /^#{rootfs_img}\s/
          if @force
            logger.warn 'Unmounting existing live image'
            cmd.run ADMIN + "umount #{rootfs_img}"
            if `mount` =~ /^#{rootfs_img}\s/ and !$DRY_RUN
              logger.error 'Failed to unmount the existing live image'
              return false
            end
          else
            logger.error 'Existing live image is mounted. Unmount and destroy it to continue.'
            return false
          end
        end
        true
      end

      def build_dir
        "/var/tmp/nest/#{name}"
      end

      def liveos_dir
        "#{build_dir}/LiveOS/squashfs-root/LiveOS"
      end

      def rootfs_img
        "#{liveos_dir}/rootfs.img"
      end
    end
  end
end
