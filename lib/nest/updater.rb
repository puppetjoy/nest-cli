# frozen_string_literal: true

require_relative 'beadm'
require 'English'
require_relative 'command_failure'

module Nest
  # Update hosts and images
  class Updater
    include Nest::CLI

    attr_reader :steps, :beadm, :options, :dir, :report

    def initialize(steps)
      @steps = steps
      @beadm = Nest::Beadm.new
    end

    def update(start, stop, options = {})
      @options = options
      @report = { schema: 1, kind: 'reset_result', success: false, phases: [], commands: [],
                  failed_phase: nil, failed_operation: nil, native_exit: nil, error: nil }

      @dir = if options[:dir]
               options[:dir]
             elsif options[:boot_env]
               "/mnt/#{boot_env}"
             else
               '/'
             end

      unless steps[start]
        logger.error "'#{start}' is not a valid step"
        report[:error] = "'#{start}' is not a valid step"
        return false
      end

      unless steps[stop]
        logger.error "'#{stop}' is not a valid step"
        report[:error] = "'#{stop}' is not a valid step"
        return false
      end

      if options[:dir] && steps.keys.index(start) <= steps.keys.index(:mount)
        logger.warn 'Skipping backup and mount steps because target directory is specified'
        start = steps.key?(:config) ? :config : :sync
      end

      if steps.keys.index(start) > steps.keys.index(stop)
        report[:error] = 'First step must not follow last step'
        return false
      end

      steps.keys[(steps.keys.index start)..(steps.keys.index stop)].each do |phase|
        @phase = phase
        outcome = { phase: phase, success: false }
        report[:phases] << outcome
        unless steps.fetch(phase).call
          report[:failed_phase] = phase
          report[:native_exit] = beadm.failure_exit_status
          report[:error] = "#{phase} failed"
          return false
        end
        outcome[:success] = true
      end
      report[:success] = true
    rescue StandardError => e
      report[:failed_phase] = @phase
      report[:failed_operation] = e.operation if e.is_a?(CommandFailure)
      report[:native_exit] = e.is_a?(CommandFailure) ? e.exit_status : beadm.failure_exit_status
      report[:error] = e.message
      raise
    end

    protected

    def backup
      return false if beadm.list.include?(boot_env) && !beadm.destroy(boot_env)

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

    def ensure_target_mounted
      check_status(:mountpoint, forcecmd.run!('mountpoint', '-q', dir).exit_status) if options[:boot_env]
      true
    end

    def reload_kexec
      return true unless options[:boot_env] && File.exist?('/etc/default/kexec-load')

      result = cmd.run! "#{ADMIN}cp -a #{dir}/etc/default/kexec-load /etc/default/kexec-load && " \
                        "#{ADMIN}systemctl try-reload-or-restart kexec-load"
      check_status(:kexec, result.exit_status)
    end

    def check_status(operation, status, accepted = [0])
      report[:commands] << { phase: @phase, operation: operation, native_exit: status,
                             success: accepted.include?(status) }
      raise CommandFailure.new(operation, status) unless accepted.include?(status)

      true
    end

    private

    def boot_env
      if options[:boot_env]
        beadm.current == 'A' ? 'B' : 'A'
      else
        "#{beadm.current}.old"
      end
    end

    def run(command, runner: cmd, directout: false)
      if dir == '/'
        cmdopts = directout ? { out: command_output, err: '/dev/stderr' } : {}
        runner.run!(ADMIN + command, cmdopts).exit_status
      else
        directout = :stderr if directout && options[:format] == 'json'
        nspawn(dir, command, runner: runner, directout: directout, home: options[:dir].nil?, srv: options[:dir].nil?)
      end
    end

    def command_output
      options[:format] == 'json' ? '/dev/stderr' : '/dev/stdout'
    end
  end
end
