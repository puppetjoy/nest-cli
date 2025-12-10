# frozen_string_literal: true

require 'shellwords'

module Nest
  class Installer
    # iPXE installer: copies image to NFS export and generates .ipxe
    class IPXE < Installer
      attr_reader :export_root

      def initialize(name, image, platform, role, export_root)
        super(name, image, platform, role)
        @export_root = export_root
      end

      def install(boot, disk, encrypt, force, start = :partition, stop = :firmware, ashift = 9,
                  supports_encryption: false)
        _ = supports_encryption
        # Use base sequencing but mark encryption unsupported; IPXE overrides methods as needed
        super(boot, disk, encrypt, force, start, stop, ashift, supports_encryption: false)
      end

      def partition
        # Ensure export root exists and target path is clear
        target_path = target
        ipxe_path = File.join(File.dirname(target_path), "#{name}.ipxe")

        unless Dir.exist?(export_root)
          if @force
            logger.warn "Creating export root #{export_root}"
            cmd.run ADMIN + "mkdir -p #{export_root}"
          else
            logger.error "Export root #{export_root} does not exist"
            logger.error "Create it or use '--force' to continue"
            return false
          end
        end

        if Dir.exist?(target_path)
          if @force
            logger.warn "Removing existing target #{target_path}"
            cmd.run ADMIN + "rm -rf #{target_path}"
          else
            logger.error "Target #{target_path} already exists"
            logger.error "Remove it or use '--force' to continue"
            return false
          end
        end

        if File.exist?(ipxe_path)
          if @force
            logger.warn "Removing existing iPXE script #{ipxe_path}"
            cmd.run ADMIN + "rm -f #{ipxe_path}"
          else
            logger.error "iPXE script #{ipxe_path} already exists"
            logger.error "Remove it or use '--force' to continue"
            return false
          end
        end

        logger.success 'Prepared export root and target'
      end

      def format(_opts = {})
        # No filesystem formatting for iPXE/NFS-root
        true
      end

      def mount(_passphrase = nil)
        # Ensure target directory exists
        target_path = target
        logger.info 'Ensuring target directory exists'
        cmd.run ADMIN + "mkdir -p #{target_path}"
        logger.success 'Target directory ready'
      end

      def copy
        # Use base copy and then mark live via local fact
        return false unless super

        facts_dir = File.join(target, 'etc/puppetlabs/facter/facts.d')
        logger.info 'Setting live=1 fact for puppet'
        cmd.run ADMIN + "mkdir -p #{facts_dir}"
        cmd.run(ADMIN + "tee #{File.join(facts_dir, 'live.txt')} > /dev/null", in: "live=1\n")
        logger.success 'Set live=1 fact'
        true
      end

      # Use base bootloader

      def unmount
        # Nothing to unmount; ensure directory exists only
        true
      end

      def firmware
        # Generate iPXE script alongside export root
        target_path = target
        ipxe_path = File.join(File.dirname(target_path), "#{name}.ipxe")
        logger.info "Generating iPXE script at #{ipxe_path}"

        machine_id = File.read(File.join(target_path, 'etc/machine-id')).strip
        boot_dir = File.join(target_path, 'boot', machine_id)
        kernel_version = Dir.children(boot_dir).find { |d| File.directory?(File.join(boot_dir, d)) }
        unless kernel_version
          logger.error 'No kernel version directory found in boot path'
          return false
        end

        kernel_fs_path = File.join(boot_dir, kernel_version, 'linux')
        initrd_fs_path = File.join(boot_dir, kernel_version, 'initrd')
        unless File.exist?(kernel_fs_path) && File.exist?(initrd_fs_path)
          logger.error 'Kernel or initrd not found'
          return false
        end

        cmdline_path = File.join(target_path, 'etc/kernel/cmdline')
        cmdline = File.exist?(cmdline_path) ? File.read(cmdline_path).strip : ''
        # Remove existing root= options for NFS root; iPXE will provide
        filtered_cmdline = cmdline.split.reject do |tok|
          tok.start_with?('root=') || tok.start_with?('rootfstype=') || tok.start_with?('rootflags=')
        end.join(' ')

        # Compose NFS root parameters
        # Assuming export served as NFS at <boot FQDN>:<export_root>/<name>
        server_fqdn = @boot.to_s
        nfs_root = File.join(@export_root, name)
        root_params = "root=/dev/nfs nfsroot=#{server_fqdn}:#{nfs_root} rw"

        # iPXE should fetch kernel/initrd via HTTP using docroot /export/hosts
        # Relative paths from docroot: <name>/boot/<machine-id>/<version>/{linux,initrd}
        kernel_rel = File.join(name, 'boot', machine_id, kernel_version, 'linux')
        initrd_rel = File.join(name, 'boot', machine_id, kernel_version, 'initrd')

        ipxe = <<~IPXE
          #!ipxe
          set base-url http://#{server_fqdn}
          echo Booting #{name} via iPXE with NFS root
          kernel ${base-url}/#{kernel_rel.shellescape} #{root_params} #{filtered_cmdline}
          initrd ${base-url}/#{initrd_rel.shellescape}
          boot
        IPXE

        cmd.run(ADMIN + "tee #{ipxe_path} > /dev/null", in: ipxe)
        logger.success 'Generated iPXE script'
        true
      end

      def cleanup
        logger.success 'All clean!'
        true
      end

      protected

      def target
        File.join(@export_root, name)
      end

      # For iPXE/NFS-root, target is a directory, not a mountpoint
      def ensure_target_mounted
        true
      end
    end
  end
end
