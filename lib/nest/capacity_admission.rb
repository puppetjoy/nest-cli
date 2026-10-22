# frozen_string_literal: true

require_relative 'capacity_policy'

module Nest
  # Conservative supported-layout admission, not a ZFS allocation guarantee.
  class CapacityAdmission
    NUMERIC = %w[available used usedbysnapshots referenced logicalreferenced
                 quota refquota reservation refreservation].freeze
    PROPERTIES = (NUMERIC + %w[origin]).freeze

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

      # No finite limit or reservation is treated as automatically transferable.
      # Refuse rather than guess quota/refquota or inherited reservation algebra.
      datasets.each_value do |props|
        unless %w[quota refquota reservation refreservation].all? { |key| props.fetch(key).zero? }
          raise 'Unknown capacity: finite quota/refquota or reservation in pool/ancestor layout'
        end
      end
      validate_layout!(host, datasets, snapshots, stage)
      current = host.fetch('current')
      transfer = datasets.select { |name, _| name == current || name.start_with?("#{current}/") }
                         .values.sum { |props| props.fetch('used') }
      if policy.fetch('promotion_budget_bytes') < transfer
        raise 'Promotion budget is below conservative snapshot-accounting bound'
      end

      demand = policy.fetch('write_budget_bytes') + policy.fetch('promotion_budget_bytes')
      required = demand + policy.fetch('physical_reserve_bytes') + policy.fetch('slop_reserve_bytes')
      raise 'Denied capacity: physical free cannot cover budgets, reserve and slop' if physical.fetch('free') < required
      if datasets.values.any? { |p| p.fetch('available') < demand }
        raise 'Denied capacity: logical available cannot cover budgets'
      end

      observations = { 'physical_pool' => physical, 'datasets' => datasets, 'snapshots' => snapshots,
                       'source_lower_bound_bytes' => source_bytes, 'promotion_bound_bytes' => transfer,
                       'required_physical_bytes' => required, 'stage' => stage }
      raise 'Unknown capacity: accounting exceeds bounded receipt size' if JSON.generate(observations).bytesize > 32_768

      { 'admission' => 'admitted', 'admitted' => true, 'policy_sha256' => CapacityPolicy.digest(policy),
        'observations' => observations, 'observations_sha256' => Digest::SHA256.hexdigest(JSON.generate(observations)),
        'reason' => 'Supported unconstrained layout under configured budgets; native failures remain authoritative.' }
    end

    private

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
      names = read('zfs', 'list', '-Hp', '-r', '-t', 'filesystem,volume', '-o', 'name,type', pool).lines.map do |line|
        name, type = line.strip.split("\t", -1)
        unless name && (name == pool || name.start_with?("#{pool}/")) && type == 'filesystem'
          raise 'Unknown capacity: incomplete inventory or unsupported volume layout'
        end

        name
      end
      raise 'Incomplete or duplicate capacity inventory' unless names.include?(pool) && names.uniq == names

      names.sort.to_h do |name|
        properties = {}
        read('zfs', 'get', '-Hp', '-o', 'property,value', PROPERTIES.join(','), name).lines.each do |line|
          key, value = line.strip.split("\t", -1)
          raise 'Duplicate or unknown dataset accounting' if properties.key?(key) || !PROPERTIES.include?(key)

          properties[key] = key == 'origin' ? value : number(value)
        end
        raise 'Incomplete dataset capacity accounting' unless properties.keys.sort == PROPERTIES.sort

        parts = name.split('/')
        ancestors = (1...parts.size).map { |n| parts.take(n).join('/') }
        raise 'Missing inherited ancestor accounting' unless (ancestors - names).empty?

        [name, properties]
      end
    end

    def snapshots(pool, datasets)
      rows = read('zfs', 'list', '-Hp', '-r', '-t', 'snapshot', '-o', 'name,used,clones', pool).lines.map do |line|
        name, used, clones = line.strip.split("\t", -1)
        raise 'Invalid snapshot accounting' unless name&.include?('@') && datasets.key?(name.split('@').first) && clones

        { 'name' => name, 'used' => number(used), 'clones' => clones }
      end
      raise 'Duplicate snapshot accounting' unless rows.map { |row| row['name'] }.uniq.size == rows.size

      rows.sort_by { |row| row.fetch('name') }
    end

    def validate_layout!(host, datasets, snapshots, stage)
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
        next if stage != 'backup' && row['clones'].split(',').all? do |clone|
          clone == target || clone.start_with?("#{target}/")
        end

        raise 'Unknown capacity: snapshot clone dependencies'
      end
    end
  end
end
