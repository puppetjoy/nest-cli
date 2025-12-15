# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class Pine64 < Installer
      def partition(options = {})
        pre_script = [
          'table-length: 56'
        ]
        super(**options.merge(pre_script: pre_script))
      end

      def firmware
        out = boot || disk
        logger.info "Installing firmware to #{out}"
        cmd.run ADMIN + "dd if=#{image}/usr/src/u-boot/u-boot-sunxi-with-spl.bin of=#{out} seek=16"
        logger.success "Installed firmware to #{out}"
      end
    end
  end
end
