# frozen_string_literal: true

require_relative '../updater'
require_relative '../installer'
require 'socket'

module Nest
  class Updater
    # Update hosts from their Stage 3 image
    class Rsync < Updater
      attr_reader :installer

      def initialize
        @installer = Nest::Installer.for_host(Socket.gethostname)

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
        return false unless $DRY_RUN || ensure_target_mounted

        cmd.run(ADMIN + "rsync -aAHX --delete --info=progress2 root@falcon:#{installer.image}/ #{dir}",
                out: '/dev/stdout', err: '/dev/stderr')
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
