# frozen_string_literal: true

require 'English'
require 'shellwords'

module Nest
  class Runtime
    class Image < Runtime
      include Nest::CLI

      attr_reader :image

      def initialize(name)
        super()

        unless name =~ /:\S+$/
          require 'yaml'
          profile = YAML.safe_load(`#{ADMIN}facter -py profile`)['profile']

          tag = case name
                when 'stage0', %r{^tools/}
                  profile['cpu']
                when 'stage1'
                  "#{profile['cpu']}-#{profile['role']}"
                when 'stage2'
                  "#{profile['platform']}-#{profile['role']}"
                end

          name += ":#{tag}" if tag
        end

        @image = "nest/#{name}"
      end

      def exec(command = nil, options = {})
        logger.warn 'Container storage is ephemeral' unless options[:overlay]

        cmd.run!("podman pull #{image.shellescape}").success? or
          raise "Image '#{image}' not found"

        qemu_args = %w[aarch64 arm x86_64].reduce([]) do |args, arch|
          args + %W[-v /usr/bin/qemu-#{arch}:/usr/bin/qemu-#{arch}:ro] if File.exist? "/usr/bin/qemu-#{arch}"
        end

        portage_args = if options[:portage]
                         [
                           '-e', 'FEATURES=-ipc-sandbox -pid-sandbox -network-sandbox -usersandbox',
                           '-v', '/etc/portage/make.conf:/etc/portage/make.conf:ro',
                           '-v', '/var/db/repos:/var/db/repos:ro'
                         ]
                       else
                         []
                       end

        ssh_args = if options[:ssh] && File.socket?(ENV['SSH_AUTH_SOCK'])
                     %W[-e SSH_AUTH_SOCK -v #{ENV['SSH_AUTH_SOCK']}:#{ENV['SSH_AUTH_SOCK']}:ro]
                   else
                     []
                   end

        if options[:x11] && !ENV['DISPLAY'].nil?
          x11_args = %w[-e DISPLAY -e GDK_DPI_SCALE -e GDK_SCALE -e QT_AUTO_SCREEN_SCALE_FACTOR -e QT_SCALE_FACTOR]
          if ENV['DISPLAY'] =~ /^:(\d+)/
            socket = "/tmp/.X11-unix/X#{Regexp.last_match(1)}"
            cmd.run 'xhost +local:root' if File.socket?(socket) && `xhost` !~ /^LOCAL:/
            x11_args += %W[-v #{socket}:#{socket}:ro]
          end
        else
          x11_args = []
        end

        podman_cmd = %w[podman run --rm -it --dns 172.22.0.1 -e TERM]
        podman_cmd += qemu_args
        podman_cmd += portage_args
        podman_cmd += ssh_args
        podman_cmd += x11_args
        podman_cmd += %W[-v #{ENV['HOME']}:/root] if options[:home]
        podman_cmd += %w[-v /nest:/nest] if options[:nest]
        podman_cmd += %w[-v /etc/puppetlabs/puppet:/etc/puppetlabs/puppet] if options[:puppet]
        podman_cmd += options[:extra_args].shellsplit if options[:extra_args]
        podman_cmd += [image]
        podman_cmd += %W[#{ENV['SHELL']} -c #{command}] if command

        if $DRY_RUN || options[:pretty]
          # Use tty-command for pretty dry-run output
          cmd.run!(*podman_cmd).exit_status
        else
          # Avoid tty-command for pty access
          system(*podman_cmd)
          $CHILD_STATUS.exitstatus
        end
      end
    end
  end
end
