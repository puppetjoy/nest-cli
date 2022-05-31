# frozen_string_literal: true

require_relative 'beadm'

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
      return beadm.mount(boot_env) if options[:boot_env] && !$DRY_RUN

      true
    end

    def config
      status = run 'puppet agent --test'
      raise 'Failed to configure system with Puppet' unless [0, 2].include?(status)

      status = run 'puppet agent --test' if status == 2
      raise 'Failed to configure system with Puppet' unless status.zero?

      true
    end

    def pre
      logger.info 'pre'
    end

    def packages
      logger.info 'packages'
    end

    def post
      logger.info 'post'
    end

    def reconfig
      logger.info 'reconfig'
    end

    def unmount
      logger.info 'unmount'
    end

    def activate
      logger.info 'activate'
    end

    private

    def boot_env
      if options[:boot_env]
        beadm.current == 'A' ? 'B' : 'A'
      else
        "#{beadm.current}.old"
      end
    end

    def run(command)
      if dir == '/'
        cmd.run!(command).exit_status
      else
        nspawn(dir, command, home: true)
      end
    end
  end
end
