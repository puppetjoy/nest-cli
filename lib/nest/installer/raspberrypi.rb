# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class RaspberryPi < Installer
      def format(options = {})
        swap_size = platform == 'raspberrypi3' ? '1G' : '8G'
        super(**options.merge(swap_size: swap_size))
      end
    end
  end
end
