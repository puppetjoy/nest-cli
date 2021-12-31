# frozen_string_literal: true

require 'stringio'

module Nest
  # Install hosts from scratch and update existing ones
  class Installer
    include Nest::CLI

    attr_reader :name, :image, :platform, :role

    def self.for_host(name)
      image = "/nest/hosts/#{name}"

      FileTest.symlink? "#{image}/etc/portage/make.profile" or
        raise "Stage 3 image at #{image} does not exist"

      File.readlink("#{image}/etc/portage/make.profile") =~ %r{/([^/]+)/([^/]+)$} or
        raise "#{image} does not contain a valid profile"

      platform = Regexp.last_match(1)
      role     = Regexp.last_match(2)

      case platform
      when 'beagleboneblack'
        require_relative 'installer/beagleboneblack'
        Nest::Installer::BeagleBoneBlack.new(name, image, platform, role)
      when 'live'
        require_relative 'installer/live'
        Nest::Installer::Live.new(name, image, platform, role)
      when 'sopine'
        require_relative 'installer/sopine'
        Nest::Installer::Sopine.new(name, image, platform, role)
      when 'haswell', 'pinebookpro', 'raspberrypi'
        Nest::Installer.new(name, image, platform, role)
      else
        raise "Platform '#{platform}' is unsupported"
      end
    end

    def initialize(name, image, platform, role)
      @name = name
      @image = image
      @platform = platform
      @role = role
    end

    def install(disk, force, start = :partition)
      @force = force

      steps = {
        partition: -> { partition(disk) },
        format: -> { format },
        mount: -> { mount },
        copy: -> { copy },
        bootloader: -> { bootloader },
        firmware: -> { firmware(disk) }
      }

      unless steps[start]
        logger.error "'#{start}' is not a valid step"
        return false
      end

      steps.values[(steps.keys.index start)..].drop_while(&:call).empty?
    end

    def partition(disk, gpt_table_length = nil)
      logger.info "Partitioning #{disk}"

      cmd.run!("#{ADMIN}wipefs -a #{disk}").success? or
        logger.warn "Failed to wipe signatures from #{disk}"

      script = StringIO.new
      script.puts 'label: gpt'
      script.puts "table-length: #{gpt_table_length}" if gpt_table_length
      if Dir.exist? '/sys/firmware/efi'
        script.puts "start=32768, size=512MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=\"#{name}-boot\""
      else
        script.puts "size=30720, type=21686148-6449-6E6F-744E-656564454649, name=\"#{name}-bios\""
        script.puts "size=512MiB, type=BC13C2FF-59E6-4262-A352-B275FD6F7172, name=\"#{name}-boot\""
      end
      script.puts "name=\"#{name}\""
      script.rewind

      script_debug = -> { script.each_line { |line| logger.debug 'sfdisk:', line.chomp } }
      if $DRY_RUN
        logger.log_at :debug do
          script_debug.call
        end
      else
        script_debug.call
      end
      script.rewind

      if cmd.run!("#{ADMIN}sfdisk #{disk}", in: script).failure?
        logger.error "Failed to partition #{disk}"
        return false
      end

      logger.success "#{disk} is partitioned"
    end

    def format
      logger.warn 'Format placeholder'
    end

    def mount
      logger.warn 'Mount placeholder'
    end

    def copy
      logger.warn 'Copy placeholder'
    end

    def bootloader
      logger.warn 'Bootloader placeholder'
    end

    def firmware(_disk)
      logger.warn 'Firmware placeholder'
    end
  end
end
