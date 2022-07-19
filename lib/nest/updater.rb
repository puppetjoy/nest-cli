# frozen_string_literal: true

require_relative 'beadm'
require 'English'

module Nest
  # Update hosts and images
  class Updater
    include Nest::CLI

    attr_reader :steps, :beadm, :options, :dir

    def initialize(steps)
      @steps = steps
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

    protected

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

    def run(command, runner: cmd, directout: false)
      if dir == '/'
        cmdopts = directout ? { out: '/dev/stdout', err: '/dev/stderr' } : {}
        runner.run!(ADMIN + command, cmdopts).exit_status
      else
        nspawn(dir, command, runner: runner, directout: directout, home: options[:dir].nil?, srv: options[:dir].nil?)
      end
    end
  end
end
