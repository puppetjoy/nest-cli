# frozen_string_literal: true

require_relative '../updater'

module Nest
  class Updater
    # Update hosts from their Stage 3 image
    class Rsync < Updater
      def initialize
        steps = {
          backup: -> { backup },
          mount: -> { mount },
          sync: -> { sync },
          kernel: -> { kernel },
          unmount: -> { unmount },
          activate: -> { activate },
          firmware: -> { firmware }
        }

        super(steps)
      end

      def update(start, stop, options = {})
        super(start, stop, options.merge({ boot_env: !(options[:kernel] || options[:firmware]) }))
      end

      protected

      def sync
        logger.info "sync -> #{dir}"
      end

      def kernel
        logger.info "kernel -> #{dir}"
      end

      def firmware
        logger.info "firmware -> #{dir}"
      end
    end
  end
end
