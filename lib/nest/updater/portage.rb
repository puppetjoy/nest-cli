# frozen_string_literal: true

require_relative '../updater'

module Nest
  class Updater
    # Update hosts using the package manager
    class Portage < Updater
      def initialize
        steps = {
          backup: -> { backup },
          mount: -> { mount },
          config: -> { config },
          pre: -> { pre },
          packages: -> { packages },
          post: -> { post },
          reconfig: -> { reconfig },
          unmount: -> { unmount },
          activate: -> { activate }
        }

        super(steps)
      end

      protected

      def config
        return false unless $DRY_RUN || ensure_target_mounted

        run_puppet
      end

      def pre
        return false unless $DRY_RUN || ensure_target_mounted

        if File.exist?("#{dir}/etc/nest/pre-update.sh")
          stop_puppet
          status = run('/etc/nest/pre-update.sh', directout: true)
          raise 'Failed to run pre-update script' unless status.zero?
        end

        true
      end

      def packages
        return false unless $DRY_RUN || ensure_target_mounted

        stop_puppet

        if run('eix -eu sys-apps/portage > /dev/null', runner: forcecmd).zero?
          run("#{emerge} -1 sys-apps/portage", directout: true)
          # allow failure due to complex dependencies
        end

        extra_args = options[:extra_args] ? " #{options[:extra_args]}" : ''
        status = run("#{emerge} -DuN --with-bdeps=y --keep-going#{extra_args} @world", directout: true)
        raise 'Failed to update system' unless status.zero?

        status = run("#{emerge} --depclean", directout: true)
        raise 'Failed to remove unnecessary packages' unless status.zero?

        true
      end

      def post
        return false unless $DRY_RUN || ensure_target_mounted

        if File.exist?("#{dir}/etc/nest/post-update.sh")
          stop_puppet
          status = run('/etc/nest/post-update.sh', directout: true)
          raise 'Failed to run post-update script' unless status.zero?
        end

        true
      end

      def reconfig
        return false unless $DRY_RUN || ensure_target_mounted

        run_puppet(kernel: true)
        reload_kexec

        true
      end

      private

      def emerge
        command = 'emerge'
        command += ' -p' if options[:noop]
        command += ' -v' if options[:verbose]
        command
      end

      def stop_puppet
        return unless dir == '/'

        run 'systemctl stop puppet-run.service puppet-run.timer' \
          if system 'systemctl --quiet is-active puppet-run.service puppet-run.timer'
      end

      def run_puppet(kernel: false)
        stop_puppet

        env = kernel ? 'FACTER_build=kernel FACTER_force_kernel_install=1 ' : ''
        args = options[:noop] ? ' --noop' : ''
        status = run("#{env}puppet agent --test#{args}", directout: true)
        raise 'Failed to configure system with Puppet' unless [0, 2].include?(status)

        # Rerun to ensure idempotence
        status = run('puppet agent --test --use_cached_catalog', directout: true) if status == 2
        raise 'Failed to configure system with Puppet' unless status.zero?

        true
      end
    end
  end
end
