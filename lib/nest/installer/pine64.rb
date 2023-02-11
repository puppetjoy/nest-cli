# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class Pine64 < Installer
      def partition(disk)
        super(disk, 56)
      end

      def firmware(disk)
        logger.info "Installing firmware to #{disk}"
        cmd.run ADMIN + "dd if=#{image}/usr/src/u-boot/u-boot-sunxi-with-spl.bin of=#{disk} seek=16"
        logger.success "Installed firmware to #{disk}"
      end
    end
  end
end
