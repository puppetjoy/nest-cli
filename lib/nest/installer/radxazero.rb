# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class RadxaZero < Installer
      def partition(options = {})
        super(**options.merge(start: 4096))
      end

      def format(options = {})
        super(**options.merge(swap_size: '8G'))
      end

      def firmware
        out = boot || disk

        # Firmware overwrites GPT :(
        logger.warn 'Converting GPT to MBR!'
        cmd.run ADMIN + "gdisk #{out}", in: "r\ng\nw\ny\n"

        logger.info "Installing firmware to #{out}"
        cmd.run ADMIN + "dd if=#{image}/usr/src/fip/radxa-zero/u-boot.bin.sd.bin of=#{out} skip=1 seek=1"
        cmd.run ADMIN + "dd if=#{image}/usr/src/fip/radxa-zero/u-boot.bin.sd.bin of=#{out} bs=1 count=440"
        logger.success "Installed firmware to #{out}"
      end
    end
  end
end
