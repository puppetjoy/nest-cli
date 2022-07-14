# frozen_string_literal: true

require_relative 'beadm'
require 'English'

module Nest
  # Update hosts and images
  class Updater
    include Nest::CLI

    attr_reader :beadm, :options, :dir

    def initialize
      @beadm = Nest::Beadm.new
    end

    def update(start, stop, options = {})
      @options = options

      @dir = if options[:dir]
               options[:dir]
             elsif options[:boot_env]
               "/mnt/#{boot_env}"
             else
               '/'
             end

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

      unless steps[start]
        logger.error "'#{start}' is not a valid step"
        return false
      end

      unless steps[stop]
        logger.error "'#{stop}' is not a valid step"
        return false
      end

      if options[:dir] && steps.keys.index(start) <= steps.keys.index(:mount)
        logger.warn 'Skipping backup and mount steps because target directory is specified'
        start = :config
      end

      steps.values[(steps.keys.index start)..(steps.keys.index stop)].drop_while(&:call).empty?
    end

    def backup
      beadm.destroy(boot_env) if beadm.list.include?(boot_env)
      beadm.create(boot_env) || $DRY_RUN
    end

    def mount
      return true unless options[:boot_env]

      if $DRY_RUN
        logger.warn "Would mount boot environment '#{boot_env}'"
      else
        beadm.mount(boot_env)
      end
    end

    def config
      run 'systemctl stop puppet-run.service puppet-run.timer' if dir == '/'
      puppet
    end

    def pre
      # Config step reenables the Puppet timer
      run 'systemctl stop puppet-run.timer' if dir == '/'

      if File.exist?("#{dir}/etc/nest/pre-update.sh")
        status = run '/etc/nest/pre-update.sh'
        raise 'Failed to run pre-update script' unless status.zero?
      end

      true
    end

    def packages
      if run('eix -eu sys-apps/portage > /dev/null', runner: forcecmd).zero?
        status = run "#{emerge} -1 sys-apps/portage"
        raise 'Failed to update Portage' unless status.zero?
      end

      extra_args = options[:extra_args] ? " #{options[:extra_args]}" : ''
      status = run "#{emerge} -DuN --with-bdeps=y --keep-going#{extra_args} @world"
      raise 'Failed to update system' unless status.zero?

      status = run "#{emerge} --depclean"
      raise 'Failed to remove unnecessary packages' unless status.zero?

      true
    end

    def post
      if File.exist?("#{dir}/etc/nest/post-update.sh")
        status = run '/etc/nest/post-update.sh'
        raise 'Failed to run post-update script' unless status.zero?
      end

      true
    end

    def reconfig
      puppet(kernel: true)

      if dir == '/'
        run 'systemctl start puppet-run.timer'
      elsif File.exist?('/etc/default/kexec-load') && options[:boot_env]
        run "cp -a #{dir}/etc/default/kexec-load /etc/default/kexec-load && systemctl try-reload-or-restart kexec-load"
      end

      true
    end

    def unmount
      return true unless options[:boot_env]

      if $DRY_RUN
        logger.warn "Would unmount boot environment '#{boot_env}'"
      else
        beadm.unmount(boot_env)
      end
    end

    def activate
      return true unless options[:boot_env]

      if $DRY_RUN
        logger.warn "Would activate boot environment '#{boot_env}'"
      else
        beadm.activate(boot_env)
      end
    end

    private

    def boot_env
      if options[:boot_env]
        beadm.current == 'A' ? 'B' : 'A'
      else
        "#{beadm.current}.old"
      end
    end

    def emerge
      command = 'emerge'
      command += ' -p' if options[:noop]
      command += ' -v' if options[:verbose]
      command
    end

    def stop_puppet
      # TODO
    end

    def puppet(kernel: false)
      env = kernel ? 'FACTER_build=kernel ' : ''
      args = options[:noop] ? ' --noop' : ''
      status = run "#{env}puppet agent --test#{args}"
      raise 'Failed to configure system with Puppet' unless [0, 2].include?(status)

      # Rerun to ensure idempotence
      status = run 'puppet agent --test' if status == 2
      raise 'Failed to configure system with Puppet' unless status.zero?

      true
    end

    def run(command, runner: cmd)
      if dir == '/'
        runner.run!(command).exit_status
      else
        nspawn(dir, command, runner: runner, home: options[:dir].nil?, srv: options[:dir].nil?)
      end
    end
  end
end
