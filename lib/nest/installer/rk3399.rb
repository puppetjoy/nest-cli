# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class RK3399 < Installer
      def partition(options = {})
        super(**options.merge(start: 32_768))
      end

      def format(options = {})
        super(**options.merge(swap_size: '8G'))
      end

      def firmware
        out = boot || disk

        logger.info "Installing firmware to #{out}"
        cmd.run ADMIN + "dd if=#{image}/usr/src/u-boot/idbloader.img of=#{out} seek=64"
        cmd.run ADMIN + "dd if=#{image}/usr/src/u-boot/u-boot.itb of=#{out} seek=16384"
        logger.success "Installed firmware to #{out}"
      end
    end
  end
end
