# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class PinebookPro < Installer
      def format(passphrase = nil)
        super(passphrase, '8G')
      end

      def firmware(disk)
        logger.info "Installing firmware to #{disk}"
        cmd.run ADMIN + "dd if=#{image}/usr/src/u-boot/idbloader.img of=#{disk} seek=64"
        cmd.run ADMIN + "dd if=#{image}/usr/src/u-boot/u-boot.itb of=#{disk} seek=16384"
        logger.success "Installed firmware to #{disk}"
      end
    end
  end
end
