# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class MilkvPioneer < Installer
      def partition(disk)
        super(disk)
        make_hybrid_mbr(disk)
      end
    end
  end
end
