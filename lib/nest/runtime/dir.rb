# frozen_string_literal: true

require 'English'
require 'shellwords'

module Nest
  class Runtime
    # Run commands in a root directory with systemd-nspawn
    class Dir < Runtime
      include Nest::CLI

      attr_reader :dir

      def initialize(dir)
        super()
        @dir = dir
      end

      def exec(command = nil, options = {})
        qemu_args = %w[aarch64 arm x86_64].reduce([]) do |args, arch|
          args + ["--bind-ro=/usr/bin/qemu-#{arch}"] if File.exist? "/usr/bin/qemu-#{arch}"
        end

        portage_args = if options[:portage]
                         [
                           '-E', 'FEATURES=-ipc-sandbox -pid-sandbox -network-sandbox -usersandbox',
                           '--bind-ro=/etc/portage/make.conf',
                           '--bind-ro=/var/db/repos'
                         ]
                       else
                         []
                       end

        ssh_args = if options[:ssh] && File.socket?(ENV['SSH_AUTH_SOCK'])
                     %W[-E SSH_AUTH_SOCK --bind-ro=#{ENV['SSH_AUTH_SOCK']}]
                   else
                     []
                   end

        if options[:x11] && !ENV['DISPLAY'].nil?
          x11_args = %w[-E DISPLAY -E GDK_DPI_SCALE -E GDK_SCALE -E QT_AUTO_SCREEN_SCALE_FACTOR -E QT_SCALE_FACTOR]
          if ENV['DISPLAY'] =~ /^:(\d+)/
            socket = "/tmp/.X11-unix/X#{Regexp.last_match(1)}"
            cmd.run 'xhost +local:root' if File.socket?(socket) && `xhost` !~ /^LOCAL:/
            x11_args += ["--bind-ro=#{socket}"]
          end
        else
          x11_args = []
        end

        cmd_args = if command
                     %W[-q -- #{ENV['SHELL']} -c #{command}]
                   else
                     %W[-- #{ENV['SHELL']}]
                   end

        nspawn_cmd = ADMIN.shellsplit + %W[systemd-nspawn -D #{@dir} --link-journal=no --resolv-conf=replace-stub]
        nspawn_cmd += ['--volatile=overlay'] if options[:overlay]
        nspawn_cmd += qemu_args
        nspawn_cmd += portage_args
        nspawn_cmd += ssh_args
        nspawn_cmd += x11_args
        nspawn_cmd += %W[--bind=#{ENV['HOME']} --bind=/root] if options[:home]
        nspawn_cmd += ['--bind=/nest'] if options[:nest]
        nspawn_cmd += ['--bind=/etc/puppetlabs/puppet:/etc/puppetlabs/puppet'] if options[:puppet]
        nspawn_cmd += options[:extra_args].shellsplit if options[:extra_args]
        nspawn_cmd += cmd_args

        if $DRY_RUN || options[:pretty]
          # Use tty-command for pretty dry-run output
          cmd.run!(*nspawn_cmd).exit_status
        else
          # Avoid tty-command for pty accesss
          system(*nspawn_cmd)
          $CHILD_STATUS.exitstatus
        end
      end
    end
  end
end
