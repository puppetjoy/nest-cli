# frozen_string_literal: true

require_relative 'capacity_policy'

module Nest
  # Conservative supported-layout admission, not a ZFS allocation guarantee.
  class CapacityAdmission
    NUMERIC = %w[available used usedbysnapshots referenced logicalreferenced
                 quota refquota reservation refreservation].freeze
    PROPERTIES = (NUMERIC + %w[origin]).freeze
    VOLUME_PROPERTIES = %w[used usedbysnapshots referenced logicalreferenced reservation refreservation
                           volsize volblocksize origin].freeze
    ACCOUNTING_CONTRACT = 3
    READABLE_CONTRACTS = [2, ACCOUNTING_CONTRACT].freeze

    def initialize(observation)
      @observation = observation
    end

    def call(policy, host, source, stage: 'backup')
      policy = CapacityPolicy.validate(policy)
      bindings = { 'release' => source.fetch('release'), 'hostname' => host.fetch('hostname'),
                   'host_identity_sha256' => Digest::SHA256.hexdigest(host.fetch('machine_id')),
                   'pool_guid' => host.fetch('pool_guid'), 'source_guid' => source.fetch('guid') }
      unless bindings.all? { |key, value| policy[key] == value }
        raise 'Capacity policy release/host/pool/source mismatch'
      end

      pool = host.fetch('current').split('/').first
      raise 'Capacity source must be in the destination pool' unless source.fetch('dataset').split('/').first == pool

      physical = pool_properties(pool)
      datasets = datasets(pool)
      snapshots = snapshots(pool, datasets)
      affected = affected_datasets(host, source, datasets, stage)
      datasets.each do |name, properties|
        snapshot_used = snapshots.select { |row| row.fetch('name').split('@').first == name }
                                 .sum { |row| row.fetch('used') }
        unless properties.fetch('usedbysnapshots').between?(snapshot_used, properties.fetch('used'))
          raise 'Unknown capacity: inconsistent snapshot accounting'
        end
      end
      source_bytes = datasets.fetch(source.fetch('dataset')).values_at('referenced', 'logicalreferenced').max
      apparent = read('du', '--apparent-size', '--block-size=1', '--summarize',
                      '--one-file-system', source.fetch('path'))
      size, path = apparent.strip.split("\t", -1)
      raise 'Invalid source apparent-size accounting' unless path == source.fetch('path')

      source_bytes = [source_bytes, number(size)].max
      raise 'Write budget is below immutable source lower bound' if policy.fetch('write_budget_bytes') < source_bytes

      shared = shared_ancestors(host, datasets, affected)
      validate_limits!(datasets, affected, shared, policy)
      validate_layout!(host, source, datasets, snapshots, stage)
      current = host.fetch('current')
      transfer = datasets.select { |name, _| name == current || name.start_with?("#{current}/") }
                         .values.sum { |props| props.fetch('used') }
      if policy.fetch('promotion_budget_bytes') < transfer
        raise 'Promotion budget is below conservative snapshot-accounting bound'
      end

      demand = policy.fetch('write_budget_bytes') + policy.fetch('promotion_budget_bytes')
      required = demand + policy.fetch('physical_reserve_bytes') + policy.fetch('slop_reserve_bytes')
      raise 'Denied capacity: physical free cannot cover budgets, reserve and slop' if physical.fetch('free') < required
      if affected.any? { |name| datasets.fetch(name).fetch('available') < demand }
        raise 'Denied capacity: logical available cannot cover budgets'
      end

      observations = { 'physical_pool' => physical, 'datasets' => datasets, 'snapshots' => snapshots,
                       'affected_datasets' => affected, 'accounting_contract' => ACCOUNTING_CONTRACT,
                       'shared_ancestors' => shared,
                       'source_lower_bound_bytes' => source_bytes, 'promotion_bound_bytes' => transfer,
                       'required_physical_bytes' => required, 'stage' => stage }
      raise 'Unknown capacity: accounting exceeds bounded receipt size' if JSON.generate(observations).bytesize > 32_768

      { 'admission' => 'admitted', 'admitted' => true, 'policy_sha256' => CapacityPolicy.digest(policy),
        'observations' => observations, 'observations_sha256' => Digest::SHA256.hexdigest(JSON.generate(observations)),
        'reason' => 'Supported affected ancestry under conservative budgets; native failures are authoritative.' }
    end

    private

    # Include unlimited ancestors too: a newly added limit or replaced ancestor
    # must not be silently rebound between preparation and a native boundary.
    def shared_ancestors(host, datasets, affected)
      names = affected.select do |name|
        host.values_at('current', 'target').all? { |root| root.start_with?("#{name}/") }
      end
      names.to_h do |name|
        [name, datasets.fetch(name).slice('guid', 'quota', 'refquota', 'used', 'referenced', 'available')]
      end
    end

    def validate_limits!(datasets, affected, shared, policy)
      demand = policy.fetch('write_budget_bytes') + policy.fetch('promotion_budget_bytes')
      affected.each do |name|
        props = datasets.fetch(name)
        reserved = %w[reservation refreservation].any? { |key| props.fetch(key).positive? }
        limited = %w[quota refquota].any? { |key| props.fetch(key).positive? }
        if reserved || (limited && !shared.key?(name))
          raise "Unknown capacity: finite quota/refquota or reservation in affected ancestor layout: #{name}"
        end
        next unless shared.key?(name)

        { 'quota' => 'used', 'refquota' => 'referenced' }.each do |limit, counter|
          next if props.fetch(limit).zero?
          next if props.fetch(limit) - props.fetch(counter) >= demand

          raise "Denied capacity: shared ancestor #{limit} headroom cannot cover budgets: #{name}"
        end
      end
    end

    def read(*args)
      @observation.read(*args)
    end

    def number(value)
      raise 'Incomplete or invalid native capacity accounting' unless value&.match?(/\A[0-9]+\z/)

      Integer(value, 10)
    end

    def pool_properties(pool)
      result = {}
      read('zpool', 'get', '-Hp', '-o', 'property,value', 'size,allocated,free,freeing', pool).lines.each do |line|
        key, value = line.strip.split("\t", -1)
        if result.key?(key) || !%w[size allocated free freeing].include?(key)
          raise 'Duplicate or unknown pool accounting'
        end

        result[key] = number(value)
      end
      raise 'Incomplete physical capacity accounting' unless result.keys.sort == %w[allocated free freeing size]
      raise 'Inconsistent physical capacity accounting' unless result['allocated'] + result['free'] == result['size']

      result
    end

    def datasets(pool)
      inventory = read('zfs', 'list', '-Hp', '-r', '-t', 'filesystem,volume', '-o', 'name,type,guid', pool)
      rows = inventory.lines.map do |line|
        name, type, guid, extra = line.strip.split("\t", -1)
        unless name && (name == pool || name.start_with?("#{pool}/")) &&
               %w[filesystem volume].include?(type) && guid&.match?(/\A[1-9][0-9]*\z/) && !extra
          raise 'Unknown capacity: incomplete typed pool inventory'
        end

        [name, type, guid]
      end
      names = rows.map(&:first)
      raise 'Incomplete or duplicate capacity inventory' unless names.include?(pool) && names.uniq == names
      raise 'Duplicate capacity GUID inventory' unless rows.map(&:last).uniq.size == rows.size

      rows.sort.to_h do |name, type, guid|
        required = type == 'filesystem' ? PROPERTIES : VOLUME_PROPERTIES
        properties = {}
        read('zfs', 'get', '-Hp', '-o', 'property,value', required.join(','), name).lines.each do |line|
          key, value, extra = line.strip.split("\t", -1)
          if properties.key?(key) || !required.include?(key) || extra || value.nil? || value.empty?
            raise 'Duplicate or unknown dataset accounting'
          end

          properties[key] = key == 'origin' ? value : number(value)
        end
        raise 'Incomplete dataset capacity accounting' unless properties.keys.sort == required.sort

        parts = name.split('/')
        ancestors = (1...parts.size).map { |n| parts.take(n).join('/') }
        raise 'Missing inherited ancestor accounting' unless (ancestors - names).empty?

        [name, properties.merge('type' => type, 'guid' => guid)]
      end
    end

    def snapshots(pool, datasets)
      inventory = read('zfs', 'list', '-Hp', '-r', '-t', 'snapshot', '-o', 'name,guid,used,clones,userrefs', pool)
      rows = inventory.lines.map do |line|
        name, guid, used, clones, holds, extra = line.strip.split("\t", -1)
        unless name&.match?(/\A[^@]+@[^@]+\z/) && datasets.key?(name.split('@').first) &&
               guid&.match?(/\A[1-9][0-9]*\z/) && clones && !clones.empty? && !extra
          raise 'Invalid snapshot accounting'
        end

        { 'name' => name, 'guid' => guid, 'used' => number(used), 'clones' => clones, 'userrefs' => number(holds) }
      end
      raise 'Duplicate snapshot accounting' unless rows.map { |row| row['name'] }.uniq.size == rows.size

      ids = rows.map { |row| row['guid'] } + datasets.values.map { |props| props.fetch('guid') }
      raise 'Duplicate snapshot/dataset GUID accounting' unless ids.uniq == ids

      rows.each do |row|
        clones = row['clones'] == '-' ? [] : row['clones'].split(',', -1)
        unless clones.uniq == clones && clones.all? { |name| datasets[name]&.fetch('origin') == row['name'] }
          raise 'Unknown capacity: inconsistent snapshot clone dependencies'
        end
      end
      datasets.each do |name, props|
        next if props['origin'] == '-'
        next if rows.any? { |row| row['name'] == props['origin'] && row['clones'].split(',').include?(name) }

        raise 'Unknown capacity: missing origin/dependency accounting'
      end

      rows.sort_by { |row| row.fetch('name') }
    end

    def in_tree?(name, root)
      name == root || name.start_with?("#{root}/")
    end

    def affected_datasets(host, source, datasets, stage)
      raise 'Unknown capacity stage' unless %w[backup activation].include?(stage)

      roots = host.values_at('current', 'target') + [source.fetch('dataset')]
      if roots.uniq.size != 3 || roots.combination(2).any? { |a, b| in_tree?(a, b) || in_tree?(b, a) }
        raise 'Unknown capacity: overlapping source/current/target trees'
      end

      affected = datasets.keys.select { |name| roots.any? { |root| in_tree?(name, root) } }
      roots.each do |root|
        parts = root.split('/')
        affected.concat((1...parts.size).map { |n| parts.take(n).join('/') })
      end
      affected = affected.uniq.sort
      if datasets.keys.any? { |name| name.start_with?("#{source.fetch('dataset')}/") }
        raise 'Unknown capacity: source inventory is no longer one immutable filesystem'
      end

      affected.each do |name|
        raise 'Missing affected ancestor accounting' unless datasets.key?(name)
        unless datasets[name]['type'] == 'filesystem'
          raise "Unknown capacity: unsupported volume in affected closure: #{name}"
        end
      end
      bindings = host.fetch('current_tree') + host.fetch('alternate_tree') +
                 [{ 'dataset' => source.fetch('dataset'), 'guid' => source.fetch('guid') }]
      bindings.each do |row|
        raise 'Changed affected dataset GUID' unless datasets[row.fetch('dataset')]&.fetch('guid') == row.fetch('guid')
      end
      targets = datasets.keys.select { |name| in_tree?(name, host.fetch('target')) }.sort
      unless targets == host.fetch('alternate_tree').map { |row| row.fetch('dataset') }.sort
        raise 'Incomplete bound alternate-tree capacity inventory'
      end

      affected
    end

    def validate_layout!(host, source, datasets, snapshots, stage)
      current = host.fetch('current')
      target = host.fetch('target')
      expected = host.fetch('current_tree').map { |row| row.fetch('dataset') }.sort
      actual = datasets.keys.select { |name| name == current || name.start_with?("#{current}/") }.sort
      raise 'Incomplete current-tree capacity inventory' unless expected == actual

      suffix = "beadm-clone-#{current.split('/').last}-to-#{target.split('/').last}"
      if stage != 'backup'
        expected_targets = expected.map { |name| name.sub(current, target) }
        targets = datasets.keys.select { |name| name == target || name.start_with?("#{target}/") }.sort
        raise 'Unknown capacity: unexpected promotion target layout' unless targets == expected_targets
      end
      host.fetch('current_tree').each do |row|
        name = row.fetch('dataset')
        raise 'Unknown capacity: current origin dependency' unless datasets.fetch(name).fetch('origin') == '-'

        snapshot = "#{name}@#{suffix}"
        candidate = name.sub(current, target)
        origin = datasets[candidate]&.fetch('origin')
        if stage == 'backup'
          raise 'Snapshot-name collision before backup' if snapshots.any? { |s| s['name'] == snapshot }
        else
          snap = snapshots.find { |s| s['name'] == snapshot }
          unless origin == snapshot && snap && snap['clones'] == candidate
            raise 'Unknown capacity: promotion origin/dependency accounting'
          end
        end
      end
      snapshots.each do |row|
        name = row.fetch('name').split('@').first
        if name == target || name.start_with?("#{target}/")
          raise 'Unknown capacity: target snapshots may collide during promotion'
        end
        next if row['clones'] == '-'

        clones = row['clones'].split(',')
        roots = [current, target, source.fetch('dataset')]
        next unless ([name] + clones).any? { |entry| roots.any? { |root| in_tree?(entry, root) } }
        # Retain old origins; the exact bound alternate is their only dependent.
        next if in_tree?(name, current) && clones == [name.sub(current, target)] &&
                datasets.fetch(clones.first).fetch('origin') == row['name']

        raise 'Unknown capacity: snapshot clone dependencies'
      end
      datasets.each do |name, props|
        next unless [current, target, source.fetch('dataset')].any? { |root| in_tree?(name, root) }
        next if props['origin'] == '-'
        next if in_tree?(name, target) && snapshots.any? do |row|
          row['name'] == props['origin'] && row['name'].split('@').first == name.sub(target, current) &&
          row['clones'] == name
        end

        raise 'Unknown capacity: affected origin dependency crosses closure'
      end
    end
  end
end
