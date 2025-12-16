# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class BeagleBoneBlack < Installer
      def partition(options = {})
        pre_script = [
          'first-lba: 4096' # U-Boot is ~3000 sectors long
        ]
        super(**options.merge(pre_script: pre_script))
      end

      def format(options = {})
        super(**options.merge(swap_size: '1536M'))
      end

      def firmware
        out = boot || disk

        logger.info "Installing firmware to #{out}"
        cmd.run ADMIN + "dd if=#{image}/usr/src/u-boot/MLO of=#{out} seek=256"
        cmd.run ADMIN + "dd if=#{image}/usr/src/u-boot/u-boot.img of=#{out} seek=768"
        logger.success "Installed firmware to #{out}"
      end
    end
  end
end
