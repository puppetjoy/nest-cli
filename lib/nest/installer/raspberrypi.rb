# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class RaspberryPi < Installer
      def format(passphrase = nil)
        super(passphrase, '8G', autotrim: false)
      end
    end
  end
end
