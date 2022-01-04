# frozen_string_literal: true

require 'thor'

module Nest
  # Command line interfaces built with Thor
  module CLI
    THOR_ERROR = 1
    USER_ERROR = 2
    SYSTEM_ERROR = 3

    ADMIN = Process.uid.zero? ? '' : 'sudo '

    def cli_init
      $DRY_RUN = options[:dry_run]
      $LOG_DEBUG = options[:debug]
    end

    def cmd
      require 'tty-command'
      $command ||= TTY::Command.new(dry_run: $DRY_RUN, uuid: false)
    end

    def logger
      require 'tty-logger'
      $logger ||= TTY::Logger.new { |config| config.level = $LOG_DEBUG ? :debug : :info }
    end

    def prompt
      require 'tty-prompt'
      $prompt ||= TTY::Prompt.new
    end

    # Subcommand to manage ZFS boot environments
    class Beadm < Thor
      include Nest::CLI

      no_commands do
        def beadm
          cli_init
          require_relative 'beadm'
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
        beadm.create(name) or exit USER_ERROR
      rescue StandardError => e
        logger.fatal('Error:', e)
        exit SYSTEM_ERROR
      end

      desc 'destroy NAME', 'Delete the specified boot environment'
      def destroy(name)
        beadm.destroy(name) or exit USER_ERROR
      rescue StandardError => e
        logger.fatal('Error:', e)
        exit SYSTEM_ERROR
      end

      desc 'mount NAME', 'Mount a boot environment under /mnt'
      def mount(name)
        beadm.mount(name) or exit USER_ERROR
      rescue StandardError => e
        logger.fatal('Error:', e)
        exit SYSTEM_ERROR
      end

      desc 'unmount NAME', 'Unmount a boot environment under /mnt'
      map 'umount' => 'unmount'
      def unmount(name)
        beadm.unmount(name) or exit USER_ERROR
      rescue StandardError => e
        logger.fatal('Error:', e)
        exit SYSTEM_ERROR
      end

      desc 'activate [NAME]', 'Configure and enable a boot environment for mounting at boot'
      def activate(name = nil)
        beadm.activate(name) or exit USER_ERROR
      rescue StandardError => e
        logger.fatal('Error:', e)
        exit SYSTEM_ERROR
      end
    end

    # Entrypoint to the Nest CLI
    class Main < Thor
      include Nest::CLI

      no_commands do
        def installer
          cli_init
          require_relative 'installer'
          @installer ||= Nest::Installer.for_host(@name)
        rescue RuntimeError => e
          logger.error(e.message)
          exit USER_ERROR
        end
      end

      class_option :debug, type: :boolean, default: false, desc: 'Log debug messages'
      class_option :dry_run, type: :boolean, default: false,
                             desc: 'Only print actions that would modify the system'

      desc 'beadm SUBCOMMAND', 'Manage ZFS boot environments'
      subcommand 'beadm', Beadm

      desc 'install [options] NAME', 'Install a new host'
      option :clean, type: :boolean, desc: 'Just run the cleanup step'
      option :disk, aliases: '-d', required: true, desc: 'The disk to format and install on'
      option :encrypt, aliases: '-e', type: :boolean, desc: 'Use ZFS encryption'
      option :force, type: :boolean, desc: 'Try to correct unexpected system states'
      option :step, aliases: '-s', desc: 'Only run this step'
      option :begin, banner: 'STEP', default: 'partition', desc: 'The first installation step'
      option :end, banner: 'STEP', default: 'firmware', desc: 'The last installation step'
      long_desc <<-LONGDESC
        Install a new host called NAME onto DISK starting at STEP where:

        \x5 NAME is a host with a valid Stage 3 image under /nest/hosts
        \x5 DISK is a device name, like /dev/sda
        \x5 STEP is one of the following points where the installer should start and stop

        \x5* partition (default start)
        \x5* format
        \x5* mount
        \x5* copy
        \x5* bootloader
        \x5* unmount
        \x5* firmware (default stop)
        \x5* cleanup
      LONGDESC
      def install(name)
        @name = name

        if options[:clean]
          start = :cleanup
          stop  = :cleanup
        elsif options[:step]
          start = options[:step]
          stop  = options[:step]
        else
          start = options[:begin]
          stop  = options[:end]
        end

        installer.install(options[:disk],
                          options[:encrypt],
                          options[:force],
                          start.to_sym,
                          stop.to_sym) or exit USER_ERROR
      rescue StandardError => e
        logger.fatal('Error:', e)
        exit SYSTEM_ERROR
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
