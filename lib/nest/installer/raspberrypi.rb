# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class RaspberryPi < Installer
      def format(options = {})
        super(options.merge(swap_size: '8G'))
      end
    end
  end
end
