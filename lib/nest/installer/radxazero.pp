# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class RadxaZero < Installer
      def format(options = {})
        super(**options.merge(swap_size: '8G'))
      end

      def firmware(disk)
        logger.info "Installing firmware to #{disk}"
        cmd.run ADMIN + "dd if=#{image}/usr/src/fip/radxa-zero/u-boot.bin.sd.bin of=#{disk} skip=1 seek=1"
        cmd.run ADMIN + "dd if=#{image}/usr/src/fip/radxa-zero/u-boot.bin.sd.bin of=#{disk} bs=1 count=440"
        logger.success "Installed firmware to #{disk}"
      end
    end
  end
end
