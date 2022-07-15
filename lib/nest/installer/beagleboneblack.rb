# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class BeagleBoneBlack < Installer
      def format(passphrase = nil)
        super(passphrase, '1536M')
      end

      def firmware(disk)
        logger.info "Installing firmware to #{disk}"
        cmd.run ADMIN + "dd if=#{image}/usr/src/u-boot/MLO of=#{disk} seek=256"
        cmd.run ADMIN + "dd if=#{image}/usr/src/u-boot/u-boot.img of=#{disk} seek=768"
        logger.success "Installed firmware to #{disk}"
      end
    end
  end
end
