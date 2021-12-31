# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class Live < Installer
      IMAGE_SIZE = '20G'

      attr_reader :build_dir

      def initialize(name, image, platform, role)
        super(name, image, platform, role)
        @build_dir = "/var/tmp/nest/#{name}"
      end

      def install(disk, encrypt, force, start = :partition)
        super(disk, encrypt, force, start, supports_encryption: false)
      end

      def partition(_disk)
        liveos_dir = "#{build_dir}/LiveOS/squashfs-root/LiveOS"

        if File.exist? "#{liveos_dir}/rootfs.img"
          if @force
            logger.warn 'Forcing removal of existing build tree'
            cmd.run "rm -rf #{build_dir}"
          else
            logger.error "Build tree at #{build_dir} already exists. Remove it to continue."
            return false
          end
        end

        logger.info 'Making live image structure'
        cmd.run "mkdir -p #{liveos_dir}"
        cmd.run "truncate -s #{IMAGE_SIZE} #{liveos_dir}/rootfs.img"
        logger.success 'Created live image structure'
      end
    end
  end
end
