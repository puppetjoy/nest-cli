# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class RaspberryPi < Installer
      def format(options = {})
        swap_size = platform == 'raspberrypi3' ? '1G' : '8G'
        super(**options.merge(swap_size: swap_size))
      end

      def partition(disk)
        super(disk)

        return unless platform == 'raspberrypi3'

        logger.warn 'Remember to setup the hybrid MBR!'
        logger.warn 'See: https://gitlab.james.tl/nest/puppet/-/wikis/Platforms/Raspberry-Pi#hybrid-mbr'
      end
    end
  end
end
