# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class MilkvMars < Installer
      def partition(options = {})
        extra_partitions = [
          "size=4096, type=2E54B353-1271-4842-806F-E436D6AF6985, name=\"#{name}-spl\"",
          "size=8192, type=BC13C2FF-59E6-4262-A352-B275FD6F7172, name=\"#{name}-uboot\""
        ]
        super(**options.merge(extra_partitions: extra_partitions))
      end

      def firmware
        logger.info 'Installing firmware'
        cmd.run ADMIN + "dd if=#{image}/usr/src/u-boot/spl/u-boot-spl.bin.normal.out of=/dev/disk/by-partlabel/#{name}-spl"
        cmd.run ADMIN + "dd if=#{image}/usr/src/u-boot/u-boot.itb of=/dev/disk/by-partlabel/#{name}-uboot"
        logger.success 'Installed firmware'
      end
    end
  end
end
