# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class MilkvPioneer < Installer
      def partition
        return unless super

        make_hybrid_mbr(boot || disk)
      end
    end
  end
end
