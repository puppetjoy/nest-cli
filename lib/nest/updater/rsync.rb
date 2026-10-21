# frozen_string_literal: true

require_relative '../updater'
require_relative '../installer'
require 'shellwords'
require 'socket'

module Nest
  class Updater
    # Update hosts from their Stage 3 image
    class Rsync < Updater
      attr_reader :installer

      def initialize(root_generation: nil)
        @installer = if root_generation
                       Nest::Installer.for_host(Socket.gethostname, image: root_generation)
                     else
                       Nest::Installer.for_host(Socket.gethostname)
                     end

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
      rescue StandardError
        false
      end

      protected

      def sync
        return false unless $DRY_RUN || ensure_target_mounted

        test_filter = options[:test] ? '--filter=\'merge /etc/nest/reset-test-filter.rules\' ' : ''
        main_filter = '--filter=\'merge /etc/nest/reset-filter.rules\' '
        keep_awk    = '/\/\.keep_/ { sub(/\.keep_\S*/, "**"); print "P", $2 }'
        keep_cmd    = "awk #{keep_awk.shellescape} #{installer.image.shellescape}/var/db/pkg/*/*/CONTENTS | sort -u"
        keep_filter = "--filter=merge\\ <(#{keep_cmd})"
        filters     = "#{test_filter}#{main_filter}#{keep_filter}"
        protection = options[:root_generation] ? "--exclude='/boot/***' --exclude='/var/lib/nest/updates/***' " : ''
        inplace = options[:root_generation] ? '--checksum' : '--inplace'
        rsync_cmd = "#{rsync} --delete #{protection}#{filters} #{inplace} --itemize-changes --progress " \
                    "#{copy_source('/')} #{dir}"

        result = cmd.run!(ADMIN + "zsh -c #{rsync_cmd.shellescape}", out: command_output, err: '/dev/stderr')
        check_status(:root, result.exit_status)
      end

      def kernel
        return false unless $DRY_RUN || ensure_target_mounted

        kernel_src
        kernel_modules
        kernel_install
      end

      def firmware
        raise 'Firmware reset is not implemented; no firmware was updated'
      end

      private

      def copy_source(suffix)
        path = "#{installer.image}#{suffix}"
        options[:root_generation] ? path.shellescape : "root@falcon:#{path}"
      end

      def rsync
        command = 'rsync -aAHX'
        command += 'n' if options[:noop] || options[:test]
        command += 'v' if options[:verbose] || options[:test]
        command += 'c --no-times' if options[:test]
        command
      end

      def kernel_src
        dest = File.join(dir, '/usr/src/linux')
        command = "#{rsync} --delete --inplace " \
                  "--itemize-changes --progress #{copy_source('/usr/src/linux/')} #{dest}"
        result = cmd.run!(ADMIN + command, out: command_output, err: '/dev/stderr')
        check_status(:source, result.exit_status)
      end

      def kernel_modules
        modules = Dir["#{installer.image}/lib/modules/*"]
        raise 'Expected exactly one Stage 3 module directory' unless modules.size == 1

        current_modules = File.basename(modules.first)
        dest = File.join(dir, '/lib/modules')
        command = "#{rsync} --delete -f 'R #{current_modules}/**' -f 'P **' --inplace " \
                  "--itemize-changes --progress #{copy_source('/lib/modules/')} #{dest}"
        result = cmd.run!(ADMIN + command, out: command_output, err: '/dev/stderr')
        check_status(:modules, result.exit_status)
      end

      def kernel_install
        args = options[:noop] ? ' --noop' : ''
        status = run("FACTER_force_kernel_install=1 puppet agent --test --tags kernel#{args}",
                     directout: true)
        check_status(:puppet, status, [0, 2])

        reload_kexec

        true
      end
    end
  end
end
