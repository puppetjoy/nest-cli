# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class Sopine < Installer
      def partition(disk)
        super(disk, 56)
      end

      def format(passphrase = nil)
        super(passphrase, '4G', autotrim: false)
      end

      def firmware(disk)
        logger.info "Installing firmware to #{disk}"
        cmd.run ADMIN + "dd if=#{image}/usr/src/u-boot/u-boot-sunxi-with-spl.bin of=#{disk} seek=16"
        logger.success "Installed firmware to #{disk}"
      end
    end
  end
end
