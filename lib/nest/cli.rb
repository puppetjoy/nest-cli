# frozen_string_literal: true

require 'thor'

module Nest
  # Command line interfaces built with Thor
  module CLI
    THOR_ERROR = 1
    USER_ERROR = 2
    SYSTEM_ERROR = 3

    def cmd
      require 'tty-command'
      $command ||= TTY::Command.new(dry_run: $DRY_RUN, uuid: false) # rubocop:disable Style/GlobalVars
    end

    def logger
      require 'tty-logger'
      $logger ||= TTY::Logger.new # rubocop:disable Style/GlobalVars
    end

    # Subcommand to manage ZFS boot environments
    class Beadm < Thor
      include Nest::CLI

      no_commands do
        def beadm
          require_relative 'beadm'
          $DRY_RUN = options[:dry_run] # rubocop:disable Style/GlobalVars
          @beadm ||= Nest::Beadm.new
        end
      end

      desc 'status', 'Display the current and active boot environments'
      def status
        current = beadm.current
        active = beadm.active
        puts "Current boot environment: #{current}"
        puts "Active BE on next reboot: #{active}"
      rescue StandardError => e
        logger.fatal('Error:', e)
        exit SYSTEM_ERROR
      end

      desc 'list', 'Print the names of all boot environments'
      def list
        puts beadm.list
      rescue StandardError => e
        logger.fatal('Error:', e)
        exit SYSTEM_ERROR
      end

      desc 'create NAME', 'Clone the current boot environment to a new one'
      def create(name)
        exit USER_ERROR unless beadm.create(name)
      rescue StandardError => e
        logger.fatal('Error:', e)
        exit SYSTEM_ERROR
      end

      desc 'destroy NAME', 'Delete the specified boot environment'
      def destroy(name)
        exit USER_ERROR unless beadm.destroy(name)
      rescue StandardError => e
        logger.fatal('Error:', e)
        exit SYSTEM_ERROR
      end

      desc 'mount NAME', 'Mount a boot environment under /mnt'
      def mount(name)
        exit USER_ERROR unless beadm.mount(name)
      rescue StandardError => e
        logger.fatal('Error:', e)
        exit SYSTEM_ERROR
      end

      desc 'unmount NAME', 'Unmount a boot environment under /mnt'
      map 'umount' => 'unmount'
      def unmount(name)
        exit USER_ERROR unless beadm.unmount(name)
      rescue StandardError => e
        logger.fatal('Error:', e)
        exit SYSTEM_ERROR
      end

      desc 'activate [NAME]', 'Configure and enable a boot environment for mounting at boot'
      def activate(name = nil)
        exit USER_ERROR unless beadm.activate(name)
      rescue StandardError => e
        logger.fatal('Error:', e)
        exit SYSTEM_ERROR
      end
    end

    # Entrypoint to the Nest CLI
    class Main < Thor
      class_option :dry_run, type: :boolean, default: false,
                             desc: 'Only print actions that would modify the system'

      desc 'beadm SUBCOMMAND', 'Manage ZFS boot environments'
      subcommand 'beadm', Beadm

      desc 'install [options] NAME', 'Install a new host'
      def install(name)
        # empty
      end

      desc 'version', 'Print the version of this tool and exit'
      map '--version' => 'version'
      map '-v' => 'version'
      def version
        require_relative 'version'
        puts "Nest CLI v#{Nest::VERSION}"
      end

      def self.exit_on_failure?
        true
      end
    end
  end
end
