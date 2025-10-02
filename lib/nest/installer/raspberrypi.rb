# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class RaspberryPi < Installer
      def format(options = {})
        swap_size = case platform
                    when 'raspberrypi5' then '16G'
                    when 'raspberrypi3' then '1G'
                    else '8G'
                    end
        super(**options.merge(swap_size: swap_size))
      end

      def partition
        return unless super

        return true unless platform == 'raspberrypi3'

        make_hybrid_mbr(boot || disk)
      end
    end
  end
end
