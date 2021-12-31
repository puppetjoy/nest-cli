# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class PinebookPro < Installer
      def format(passphrase = nil)
        super(passphrase, '8G')
      end
    end
  end
end
