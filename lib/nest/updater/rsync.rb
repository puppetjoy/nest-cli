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

        test_filter = options[:test] ? '--filter=\'merge /etc/nest/reset-test-filter.rules\' ' : ''
        cmd.run(ADMIN + "#{rsync} --delete --filter='merge /etc/nest/reset-filter.rules' #{test_filter}" \
                        "--itemize-changes --progress root@falcon:#{installer.image}/ #{dir}",
                out: '/dev/stdout', err: '/dev/stderr')
      end

      def kernel
        return false unless $DRY_RUN || ensure_target_mounted

        kernel_src
        kernel_modules
        kernel_install
      end

      def firmware
        logger.info "firmware -> #{dir}"
      end

      private

      def rsync
        command = 'rsync -aAHX'
        command += 'n' if options[:noop] || options[:test]
        command += 'v' if options[:verbose] || options[:test]
        command += 'c --no-times' if options[:test]
        command
      end

      def kernel_src
        current_sources = File.basename Dir["#{installer.image}/usr/src/linux-*"].first
        cmd.run(ADMIN + "#{rsync} --delete -f 'R #{current_sources}/**' -f 'P **' " \
                        "--itemize-changes --progress root@falcon:'#{installer.image}/usr/src/linux*' #{dir}usr/src",
                out: '/dev/stdout', err: '/dev/stderr')
      end

      def kernel_modules
        current_modules = File.basename Dir["#{installer.image}/lib/modules/*"].first
        cmd.run(ADMIN + "#{rsync} --delete -f 'R #{current_modules}/**' -f 'P **' " \
                        "--itemize-changes --progress root@falcon:#{installer.image}/lib/modules/ #{dir}lib/modules",
                out: '/dev/stdout', err: '/dev/stderr')
      end

      def kernel_install
        args = options[:noop] ? ' --noop' : ''
        status = run('FACTER_force_kernel_install=1 puppet agent --test ' \
                     "--tags nest::base::bootloader,nest::base::dracut,nest::base::firmware#{args}", directout: true)
        raise 'Failed to install kernel' unless [0, 2].include? status

        true
      end
    end
  end
end
