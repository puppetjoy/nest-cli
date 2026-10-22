# frozen_string_literal: true

require 'json'
require 'open3'
require 'digest'
require 'socket'
require_relative 'command_failure'
require_relative 'source_identity'
require_relative 'capacity_admission'

module Nest
  # Read-only identity and mount checks. No provisioning or fallback storage.
  class UpdateObservation
    STATE = '/var/lib/nest/updates'
    FILTER = '/etc/nest/reset-filter.rules'

    def read(*args)
      output, status = Open3.capture2e(*args)
      raise CommandFailure.new("transaction observation #{args.first}", status.exitstatus) unless status.success?

      output.strip
    end

    def mounts
      output = read('findmnt', '--json', '--list', '--all', '-o', 'SOURCE,TARGET,FSTYPE,OPTIONS')
      JSON.parse(output).fetch('filesystems')
    end

    def exact_mount(path, inventory = mounts)
      rows = inventory.select { |row| row['target'] == path }
      raise "Expected one exact mount at #{path}" unless rows.size == 1 && rows.first['fstype'] == 'zfs'

      rows.first
    end

    def property(dataset, name)
      read('zfs', 'get', '-Hp', '-o', 'value', name, dataset)
    end

    def guid(dataset)
      value = property(dataset, 'guid')
      raise 'Invalid ZFS GUID' unless value.match?(/\A[1-9][0-9]*\z/)

      value
    end

    def shared_state(path = STATE)
      raise 'State path is not canonical' unless File.realpath(path) == path

      row = exact_mount(path)
      dataset = row.fetch('source')
      raise 'State must be outside all ROOT trees' if dataset.split('/').include?('ROOT')
      raise 'State must be a dedicated writable ZFS filesystem' unless property(dataset, 'mountpoint') == path &&
                                                                       property(dataset, 'readonly') == 'off' &&
                                                                       row.fetch('options').split(',').include?('rw')

      pool = dataset.split('/').first
      raise 'State pool must be host-local' unless property(pool, 'org.nest:host-id') == machine_id

      { 'dataset' => dataset, 'guid' => guid(dataset), 'pool_guid' => pool_guid(pool) }
    end

    def machine_id
      value = File.read('/etc/machine-id').strip
      raise 'Invalid machine identity' unless value.match?(/\A[0-9a-f]{32}\z/)

      value
    end

    def boot_id
      value = File.read('/proc/sys/kernel/random/boot_id').strip
      raise 'Invalid boot identity' unless value.match?(/\A[0-9a-f-]{36}\z/)

      value
    end

    def pool_guid(pool)
      value = read('zpool', 'get', '-Hp', '-o', 'value', 'guid', pool)
      raise 'Invalid pool GUID' unless value.match?(/\A[1-9][0-9]*\z/)

      value
    end

    def host
      inventory = mounts
      root = exact_mount('/', inventory).fetch('source')
      match = %r{\A(([^/\s]+)(?:/[^/\s]+)*/ROOT)/(A|B)\z}.match(root)
      raise 'Transactional reset requires an A/B ZFS root' unless match

      be_root, pool, current = match.captures
      target = "#{be_root}/#{current == 'A' ? 'B' : 'A'}"
      current_tree = tree(root)
      current_tree.each do |row|
        unless exact_mount(row.fetch('mountpoint'), inventory)['source'] == row.fetch('dataset')
          raise 'Current BE child mount identity mismatch'
        end
      end
      { 'machine_id' => machine_id, 'hostname' => Socket.gethostname, 'boot_id' => boot_id,
        'pool_guid' => pool_guid(pool), 'current' => root, 'current_tree' => current_tree,
        'alternate_tree' => tree(be_root).select do |row|
          row['dataset'] == target || row['dataset'].start_with?("#{target}/")
        end,
        'target' => target, 'next_boot' => read('zpool', 'get', '-Hp', '-o', 'value', 'bootfs', pool) }
    end

    def tree(dataset)
      inventory = read('zfs', 'list', '-Hp', '-r', '-t', 'filesystem', '-o', 'name,guid,mountpoint', dataset)
      rows = inventory.lines.map do |line|
        name, id, mountpoint = line.strip.split("\t")
        raise 'Invalid dataset tree' unless name && id&.match?(/\A[1-9][0-9]*\z/) && mountpoint &&
                                            (name == dataset || name.start_with?("#{dataset}/"))

        { 'dataset' => name, 'guid' => id, 'mountpoint' => mountpoint }
      end
      raise 'Missing dataset root' unless rows.any? { |row| row['dataset'] == dataset }

      rows.sort_by { |row| row.fetch('dataset') }
    end

    def source(path, release)
      unless path.start_with?('/') && File.realpath(path) == path
        raise 'Root generation must be a canonical absolute path'
      end
      raise 'Root generation cannot be the mutable host alias' if path == '/' || path.start_with?('/nest/hosts/')

      trusted_source_path!(path)

      inventory = mounts
      row = exact_mount(path, inventory)
      dataset = row.fetch('source')
      unless property(dataset.split('/').first, 'org.nest:host-id') == machine_id &&
             property(dataset, 'org.nest:host') == Socket.gethostname
        raise 'Root generation must be host-local and bound to this hostname'
      end

      immutable = tree(dataset).size == 1 && property(dataset, 'readonly') == 'on' &&
                  property(dataset, 'org.nest:release') == release && property(dataset, 'mountpoint') == path &&
                  row.fetch('options').split(',').include?('ro')
      raise 'Root generation must be one immutable read-only filesystem' unless immutable
      raise 'Root generation contains submounts' if inventory.any? { |m| m.fetch('target').start_with?("#{path}/") }

      %w[var/db/pkg usr/src/linux lib/modules].each { |suffix| contained_path!(path, suffix) }

      txg = property(dataset, 'createtxg')
      raise 'Invalid source creation TXG' unless txg.match?(/\A[1-9][0-9]*\z/)

      { 'path' => path, 'dataset' => dataset, 'guid' => guid(dataset),
        'creation_txg' => txg, 'release' => release }
    end

    def trusted_source_path!(path)
      loop do
        stat = File.lstat(path)
        unless stat.directory? && stat.uid.zero? && stat.mode.nobits?(0o022)
          raise 'Unsafe root generation ownership or ancestor permissions'
        end
        break if path == '/'

        path = File.dirname(path)
      end
    end

    def capacity(policy, host, source, stage: 'backup')
      CapacityAdmission.new(self).call(policy, host, source, stage: stage)
    end

    # Enumerate the pool so missing is not confused with a failed targeted read.
    def cleanup_tree(dataset, expected)
      inventory = tree(dataset.split('/').first)
      rows = inventory.select { |row| row['dataset'] == dataset || row['dataset'].start_with?("#{dataset}/") }
      ids = expected.map { |row| row.fetch('guid') }
      if inventory.any? { |row| ids.include?(row['guid']) && !rows.include?(row) }
        raise 'Owned cleanup GUID moved outside recorded tree'
      end

      rows.empty? ? nil : rows
    end

    def cleanup_safe!(dataset)
      target_unmounted!(dataset)
      tree(dataset).each do |row|
        raise 'Cleanup descendant is mounted' unless property(row.fetch('dataset'), 'mounted') == 'no'
      end
      # Refuse all candidate-local snapshots, including held/dependent ones.
      # Shared/ambiguous origins outside this tree are retained, never followed.
      snapshots = read('zfs', 'list', '-Hp', '-r', '-t', 'snapshot', '-o', 'name', dataset)
      raise 'Cleanup snapshots may be held or dependent; retain for separate policy' unless snapshots.empty?
    end

    def destroy_owned!(dataset, expected, host:)
      raise 'Owned cleanup identity changed before mutation' unless cleanup_tree(dataset, expected) == expected

      cleanup_safe!(dataset)
      raise 'Boot selection or host changed immediately before deletion' unless self.host == host

      read('zfs', 'destroy', '-r', dataset) # No -R, force, origin deletion or bootfs change.
    end

    def policy
      { 'filter_sha256' => Digest::SHA256.file(FILTER).hexdigest,
        'cli_sha256' => SourceIdentity.to_h.fetch(:source_sha256) }
    end

    def contained_path!(root, suffix)
      resolved = File.realpath(File.join(root, suffix))
      raise 'Copy path escapes its bound root' unless resolved.start_with?("#{root}/")

      resolved
    end

    def target_unmounted!(target)
      raise 'Alternate has mounted datasets' if mounts.any? do |row|
        row['source'] == target || row['source'].start_with?("#{target}/") ||
        row['target'] == "/mnt/#{target.split('/').last}" ||
        row['target'].start_with?("/mnt/#{target.split('/').last}/")
      end
    end

    def copy_target!(target, expected_tree)
      raise 'Target tree identity changed' unless tree(target) == expected_tree

      destination = "/mnt/#{target.split('/').last}"
      raise 'Destination path is not canonical' unless File.realpath(destination) == destination

      inventory = mounts
      expected = expected_tree.to_h do |row|
        mp = row.fetch('mountpoint')
        raise 'Unsafe BE mountpoint' unless mp.start_with?('/') && !mp.split('/').include?('..')

        [mp == '/' ? destination : "#{destination}#{mp}", row.fetch('dataset')]
      end
      expected.each do |path, dataset|
        raise 'Mounted destination identity mismatch' unless exact_mount(path, inventory)['source'] == dataset
      end
      nested = inventory.select { |row| row['target'] == destination || row['target'].start_with?("#{destination}/") }
      nested.each do |row|
        next if expected[row['target']] == row['source'] && row['options'].split(',').include?('rw')
        next if row['target'] == "#{destination}/boot" &&
                inventory.any? { |boot| boot['target'] == '/boot' && boot['source'] == row['source'] }

        raise 'Unexpected or read-only destination submount'
      end
      raise 'Shared state cannot be copied into the alternate' if expected.key?("#{destination}#{STATE}")

      %w[usr/src/linux lib/modules].each { |suffix| contained_path!(destination, suffix) }

      true
    end
  end
end
