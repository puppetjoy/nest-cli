# frozen_string_literal: true

require 'time'
require 'digest'
require_relative 'update_store'
require_relative 'update_observation'
require_relative 'update_lifecycle'
require_relative 'update_reboot'

module Nest
  # A native prepare transaction. Reboot, acceptance and cleanup are not implicit.
  class UpdateTransaction
    include UpdateLifecycle
    include UpdateReboot

    PHASES = %w[backup mount sync kernel unmount activate].freeze
    attr_reader :record

    def initialize(store: UpdateStore.new(UpdateObservation::STATE), observation: UpdateObservation.new)
      @store = store
      @observation = observation
    end

    def plan(release:, root_generation:, capacity_policy: nil)
      @store.validate!
      raise 'Release must be an immutable sha256 digest' unless release&.match?(/\Asha256:[0-9a-f]{64}\z/)
      raise 'Root generation is required' unless root_generation.is_a?(String)

      host = @observation.host
      source = @observation.source(root_generation, release)
      capacity = if capacity_policy
                   @observation.capacity(CapacityPolicy.read(capacity_policy), host, source)
                 else
                   { 'admission' => 'unknown', 'admitted' => nil, 'reason' => 'No capacity policy supplied' }
                 end
      { 'shared_state' => @observation.shared_state(@store.path),
        'host' => host.reject { |key, _| key == 'machine_id' },
        'source' => source, 'policy' => @observation.policy,
        'read_only' => true, 'capacity_admission' => capacity.fetch('admission'), 'capacity' => capacity }
    end

    def prepare(id, release:, root_generation:, resume: false, updater: nil, capacity_policy: nil)
      @store.id!(id)
      @store.validate!
      shared = @observation.shared_state(@store.path)
      @store.lock do
        @record = resume ? load_record(id) : create_record(id, release, root_generation, shared, capacity_policy)
        validate_resume!(release, root_generation, shared)
        validate_capacity_policy!(capacity_policy)
        unless record.fetch('phases').size == PHASES.size && record.fetch('phases').last['state'] == 'complete'
          check_capacity!(record['target_tree'] ? 'activation' : 'backup')
          save
        end
        PHASES.each do |phase|
          next if record.fetch('phases').any? { |row| row['phase'] == phase && row['state'] == 'complete' }

          updater ||= native_updater
          execute_phase(phase, updater)
          return report unless record.fetch('phases').last['state'] == 'complete'
        end
        record['state'] = 'prepared'
        save
        report
      end
    end

    # No lock creation, no write, and changed boots are observations, not retries.
    def status(id)
      @record = load_record(id)
      observed = bound_host!
      baseline = record.fetch('host')

      if record.key?('reboot')
        if observed.fetch('boot_id') == baseline.fetch('boot_id')
          reboot_identity!(historical: true)
        else
          accepted_host!
          reboot_source_policy!
        end
      end

      known_current = observed['current'] == baseline['current'] && observed['current_tree'] == baseline['current_tree']
      known_target = observed['current'] == baseline['target'] && observed['current_tree'] == record['target_tree']
      raise 'Observed current BE identity mismatch' unless known_current || known_target
      if record['target_tree'] && @observation.tree(baseline.fetch('target')) != record['target_tree']
        raise 'Observed target BE identity mismatch'
      end

      report.merge('observation' => {
                     'boot_id' => observed.fetch('boot_id'),
                     'boot_changed' => observed.fetch('boot_id') != baseline.fetch('boot_id'),
                     'current' => observed.fetch('current'), 'next_boot' => observed.fetch('next_boot'),
                     'expected_target_booted' => record['target_tree'] &&
                       observed['current'] == baseline['target'] && observed['current_tree'] == record['target_tree'],
                     'accepted' => record['schema'] == 2 &&
                       observed['boot_id'] == record.fetch('acceptance').fetch('boot_id')
                   })
    end

    # Historical reports remain exportable after later updates replace a BE.
    # This checks the host/state binding, not whether old BEs are still present.
    def export(id)
      @record = load_record(id)
      bound_host!
      report
    end

    def report
      # Allowlisted projection only: never command output, exceptions, keys or environment.
      phases = record.fetch('phases').map do |row|
        row.slice('phase', 'state', 'attempt', 'started_at', 'finished_at', 'boot_id', 'native_exit', 'commands')
      end
      prepared = %w[prepared accepted finalizing finalized].include?(record['state'])
      result = { 'schema' => record.fetch('schema'), 'kind' => 'reset_transaction_report', 'id' => record.fetch('id'),
                 'state' => record.fetch('state'), 'success' => prepared,
                 'release' => record.fetch('release'),
                 'source' => record.fetch('source').slice('path', 'dataset', 'guid', 'creation_txg', 'release'),
                 'host' => record.fetch('host').slice('hostname', 'boot_id', 'pool_guid', 'current', 'current_tree',
                                                      'alternate_tree', 'target', 'next_boot'),
                 'host_identity_sha256' => Digest::SHA256.hexdigest(record.fetch('host').fetch('machine_id')),
                 'shared_state' => record.fetch('shared_state').slice('dataset', 'guid', 'pool_guid'),
                 'target_tree' => record['target_tree'],
                 'policy' => record.fetch('policy').slice('filter_sha256', 'cli_sha256'),
                 'created_at' => record.fetch('created_at'),
                 'updated_at' => record.fetch('updated_at'), 'phases' => phases,
                 'reboot_requested' => reboot_requested, 'accepted' => record['schema'] == 2,
                 'finalized' => record['state'] == 'finalized' }
      result['capacity'] = record['capacity'] if record['capacity']
      result['reboot'] = record['reboot'].dup if record.key?('reboot')
      if record['schema'] == 2
        result.merge!(record.slice('acceptance', 'owned_candidates', 'cleanup_receipts', 'finalized_at'))
        result['snapshot_policy'] = 'retain_origins_no_reclamation_claim'
      end
      result
    end

    private

    def validate_capacity_policy!(path)
      validate_capacity_record!(record)
      capacity = record.fetch('capacity')
      policy = CapacityPolicy.validate(capacity.fetch('policy'))
      unless CapacityPolicy.digest(policy) == capacity.fetch('policy_sha256')
        raise 'Stored capacity policy digest mismatch; manual recovery required'
      end
      return unless path && CapacityPolicy.read(path) != policy

      raise 'Capacity policy cannot replace the policy bound to this transaction'
    end

    def validate_capacity_record!(data)
      return unless data.key?('capacity')

      capacity = data.fetch('capacity')
      fields = %w[checks policy policy_sha256]
      fields << 'accounting_contract' if capacity.is_a?(Hash) && capacity.key?('accounting_contract')
      raise 'Invalid stored capacity binding' unless capacity.is_a?(Hash) && capacity.keys.sort == fields.sort

      if capacity.key?('accounting_contract') &&
         CapacityAdmission::READABLE_CONTRACTS.none? { |version| capacity['accounting_contract'].eql?(version) }
        raise 'Unsupported stored capacity accounting contract'
      end

      digest = CapacityPolicy.digest(capacity.fetch('policy'))
      raise 'Stored capacity policy digest mismatch' unless digest == capacity.fetch('policy_sha256')

      checks = capacity.fetch('checks')
      raise 'Invalid stored capacity checks' unless checks.is_a?(Array) && checks.size.between?(1, 16)

      checks.each do |check|
        if capacity.key?('accounting_contract') &&
           (!check.is_a?(Hash) || !check['observations'].is_a?(Hash) ||
            !check['observations']['accounting_contract'].eql?(capacity['accounting_contract']))
          raise 'Stored capacity accounting contract mismatch'
        end

        fields = %w[admission admitted policy_sha256 observations observations_sha256 reason checked_at]
        next if check.is_a?(Hash) && (check.keys - fields).empty? && check['admitted'] == true &&
                check['admission'] == 'admitted' && check['policy_sha256'] == digest &&
                check['observations'].is_a?(Hash) &&
                check['observations_sha256'] == Digest::SHA256.hexdigest(JSON.generate(check['observations']))

        raise 'Invalid stored capacity observation digest or verdict'
      end
      return unless capacity['accounting_contract'].eql?(CapacityAdmission::ACCOUNTING_CONTRACT)

      baseline = ancestor_binding(checks.first, data.fetch('host'), capacity.fetch('policy'))
      raise 'Stored shared ancestor identity or limits changed' unless checks.all? do |check|
        ancestor_binding(check, data.fetch('host'), capacity.fetch('policy')) == baseline
      end
    end

    def ancestor_binding(check, host, policy)
      ancestors = check.fetch('observations').fetch('shared_ancestors')
      raise 'Invalid shared ancestor accounting' unless ancestors.is_a?(Hash)

      parts = host.fetch('current').split('/')
      names = (1...parts.size).map { |n| parts.take(n).join('/') }
      expected = names.select { |name| host.fetch('target').start_with?("#{name}/") }
      raise 'Incomplete shared ancestor accounting' unless ancestors.keys.sort == expected.sort

      ancestors.to_h do |name, props|
        unless name.is_a?(String) && props.is_a?(Hash) &&
               props.keys.sort == %w[available guid quota referenced refquota used] &&
               props['guid'].is_a?(String) && props['guid'].match?(/\A[1-9][0-9]*\z/) &&
               %w[quota refquota used referenced available].all? { |key| props[key].is_a?(Integer) && props[key] >= 0 }
          raise 'Invalid shared ancestor accounting'
        end

        dataset = check.fetch('observations').fetch('datasets').fetch(name)
        raise 'Shared ancestor accounting disagrees with dataset observation' unless dataset.slice(*props.keys) == props

        demand = policy.fetch('write_budget_bytes') + policy.fetch('promotion_budget_bytes')
        if props.fetch('available') < demand ||
           { 'quota' => 'used', 'refquota' => 'referenced' }.any? do |limit, counter|
             props.fetch(limit).positive? && props.fetch(limit) - props.fetch(counter) < demand
           end
          raise 'Invalid admitted shared ancestor headroom'
        end

        [name, props.slice('guid', 'quota', 'refquota')]
      end
    end

    def check_capacity!(stage)
      capacity = record.fetch('capacity')
      check = @observation.capacity(capacity.fetch('policy'), @observation.host, record.fetch('source'), stage: stage)
      raise 'Capacity accounting did not admit preparation' unless check['admitted'] == true
      unless check.fetch('observations')['accounting_contract'].eql?(CapacityAdmission::ACCOUNTING_CONTRACT)
        raise 'Fresh capacity accounting contract mismatch'
      end
      unless ancestor_binding(check, record.fetch('host'), capacity.fetch('policy')) ==
             ancestor_binding(capacity.fetch('checks').first, record.fetch('host'), capacity.fetch('policy'))
        raise 'Changed shared ancestor GUID or limits; export and inspect, never rebind'
      end

      check['checked_at'] = now
      capacity['checks'] = (capacity.fetch('checks') + [check]).last(16)
    end

    def bound_host!
      shared = @observation.shared_state(@store.path)
      raise 'Shared state identity mismatch' unless shared == record.fetch('shared_state')

      observed = @observation.host
      baseline = record.fetch('host')
      raise 'Host or pool identity mismatch' unless %w[machine_id hostname pool_guid].all? do |key|
        observed[key] == baseline[key]
      end

      observed
    end

    def load_record(id)
      data = @store.read(id)
      states = %w[pending stopped prepared accepted finalizing finalized]
      unless [1, 2].include?(data['schema']) && data['kind'] == 'reset_transaction' &&
             data['id'] == id && states.include?(data['state'])
        raise 'Invalid transaction record'
      end

      validate_lifecycle!(data)
      validate_capacity_record!(data)

      rows = data.fetch('phases')
      raise 'Invalid phase receipts' unless rows.is_a?(Array) && rows.size <= PHASES.size &&
                                            rows.map { |row| row['phase'] } == PHASES.take(rows.size) &&
                                            rows.all? { |row| %w[started failed complete].include?(row['state']) } &&
                                            rows[0...-1].all? { |row| row['state'] == 'complete' }
      raise 'Incomplete prepared receipt' if %w[prepared accepted finalizing finalized].include?(data['state']) &&
                                             (rows.size != PHASES.size || rows.last['state'] != 'complete')

      raise 'Invalid release identity' unless data.fetch('release').match?(/\Asha256:[0-9a-f]{64}\z/)

      %w[host source shared_state policy].each do |key|
        raise 'Invalid transaction binding' unless data[key].is_a?(Hash) && !data[key].empty?
      end
      rows.each do |row|
        unless row['attempt'].is_a?(Integer) && row['attempt'].positive? && row['boot_id'] == data['host']['boot_id']
          raise 'Invalid phase attempt binding'
        end

        Time.iso8601(row.fetch('started_at'))
        next if row['state'] == 'started'

        Time.iso8601(row.fetch('finished_at'))
        raise 'Missing checked command outcomes' unless row['commands'].is_a?(Array)
        if row['state'] == 'complete' && !completed_phase_success?(row)
          raise 'Completed phase contains a failed command or contradictory native exit'
        end
      end
      if rows.any? { |row| row['phase'] == 'backup' && row['state'] == 'complete' } && !data['target_tree'].is_a?(Array)
        raise 'Missing post-backup target identity'
      end

      validate_reboot!(data)
      data
    end

    # Keep native outcomes intact. Only kernel Puppet has a successful nonzero
    # detailed exit; nil retains the existing unknown-exit success semantics.
    def completed_phase_success?(row)
      row.is_a?(Hash) && row['state'] == 'complete' && successful_phase_exit?(row['native_exit']) &&
        row['commands'].is_a?(Array) && row['commands'].all? do |command|
          command.is_a?(Hash) && command['success'].equal?(true) && command['operation'].is_a?(String) &&
            (successful_phase_exit?(command['native_exit']) ||
             (row['phase'] == 'kernel' && command['operation'] == 'puppet' && command['native_exit'].eql?(2)))
        end
    end

    def successful_phase_exit?(value)
      value.nil? || value.eql?(0)
    end

    def create_record(id, release, root_generation, shared, capacity_policy)
      raise 'Release must be an immutable sha256 digest' unless release&.match?(/\Asha256:[0-9a-f]{64}\z/)
      raise 'Root generation is required' unless root_generation.is_a?(String)
      raise 'Transaction ID already exists; use --resume-transaction' if @store.ids.include?(id)

      previous = @store.ids.map do |other|
        loaded = load_record(other)
        raise 'An unresolved host transaction exists; inspect status, never replace its receipt' unless
          loaded['state'] == 'finalized'

        loaded
      end
      host = @observation.host
      unless previous.empty?
        @record = previous.max_by { |entry| entry.fetch('finalized_at') }
        accepted = accepted_host!
        raise 'Previous acceptance boot changed before next preparation' unless
          accepted['boot_id'] == record.fetch('acceptance').fetch('boot_id')
      end
      raise 'Current BE must be selected for next boot before preparation' unless host['next_boot'] == host['current']

      @observation.target_unmounted!(host.fetch('target'))
      source = @observation.source(root_generation, release)
      raise 'New preparation requires --capacity-policy FILE' unless capacity_policy

      capacity = CapacityPolicy.read(capacity_policy)
      admission = @observation.capacity(capacity, host, source)
      unless admission['admitted'] == true &&
             admission.fetch('observations')['accounting_contract'].eql?(CapacityAdmission::ACCOUNTING_CONTRACT)
        raise 'New preparation requires current capacity accounting admission'
      end

      ancestor_binding(admission, host, capacity)
      { 'schema' => 1, 'kind' => 'reset_transaction', 'id' => id, 'state' => 'pending',
        'release' => release, 'source' => source, 'host' => host, 'shared_state' => shared,
        'capacity' => { 'accounting_contract' => CapacityAdmission::ACCOUNTING_CONTRACT,
                        'policy' => capacity, 'policy_sha256' => CapacityPolicy.digest(capacity),
                        'checks' => [admission] },
        'policy' => @observation.policy, 'target_tree' => nil, 'phases' => [], 'created_at' => now }
    end

    def validate_resume!(release, root_generation, shared)
      raise 'Reboot intent forbids preparation replay; inspect status' if record.key?('reboot')
      raise 'Accepted transactions cannot resume preparation' unless record['schema'] == 1
      raise 'Release mismatch' if release && release != record.fetch('release')
      raise 'Root generation mismatch' if root_generation && root_generation != record.fetch('source').fetch('path')
      raise 'Shared state identity mismatch' unless shared == record.fetch('shared_state')
      unless record['capacity']
        raise 'Historical preparation lacks capacity admission; export report and inspect native state ' \
              'for manual recovery, never replay'
      end

      unless record['capacity']['accounting_contract'].eql?(CapacityAdmission::ACCOUNTING_CONTRACT)
        raise 'Historical preparation has stale capacity accounting contract; export and inspect, never replay'
      end

      validate_identity!
      last = record.fetch('phases').last
      return unless last && last['state'] != 'complete'
      return if last['phase'] == 'sync'

      raise "Ambiguous or failed #{last['phase']} boundary; observation and manual recovery required, never replay"
    end

    def validate_identity!
      unless @observation.shared_state(@store.path) == record.fetch('shared_state')
        raise 'Shared state identity changed'
      end

      observed = @observation.host
      baseline = record.fetch('host')
      raise 'Host, boot, pool or current BE identity mismatch' unless
        %w[machine_id hostname boot_id pool_guid current current_tree target].all? do |key|
          observed[key] == baseline[key]
        end

      expected_next = if record.fetch('phases').any? { |p| p['phase'] == 'activate' && p['state'] == 'complete' }
                        baseline.fetch('target')
                      else
                        baseline.fetch('current')
                      end
      raise 'Next boot selection changed; inspect before continuing' unless observed['next_boot'] == expected_next
      raise 'Immutable root generation changed' unless
        @observation.source(record.fetch('source').fetch('path'), record.fetch('release')) == record.fetch('source')
      raise 'Reset policy or installed CLI changed' unless @observation.policy == record.fetch('policy')
      if !record['target_tree'] && observed['alternate_tree'] != baseline['alternate_tree']
        raise 'Preexisting alternate identity changed'
      end
      return unless record['target_tree']
      return if @observation.tree(baseline.fetch('target')) == record.fetch('target_tree')

      raise 'Alternate identity changed'
    end

    def execute_phase(phase, updater)
      validate_identity!
      target = record.fetch('host').fetch('target')
      @observation.target_unmounted!(target) if phase == 'backup'
      @observation.copy_target!(target, record.fetch('target_tree')) if %w[sync kernel].include?(phase)
      check_capacity!(phase == 'backup' ? 'backup' : 'activation') if %w[backup sync activate].include?(phase)
      previous = record.fetch('phases').last
      attempt = previous && previous['phase'] == phase ? record.fetch('phases').pop.fetch('attempt') + 1 : 1
      receipt = { 'phase' => phase, 'state' => 'started', 'attempt' => attempt,
                  'started_at' => now, 'boot_id' => record.fetch('host').fetch('boot_id') }
      record.fetch('phases') << receipt
      record['state'] = 'pending'
      save # Must be durable BEFORE the first native side effect.
      if %w[backup activate].include?(phase)
        check_capacity!(phase == 'backup' ? 'backup' : 'activation')
        save
      end
      success = updater.update(phase.to_sym, phase.to_sym,
                               root_generation: record.fetch('source').fetch('path'), format: 'json')
      result = updater.report
      receipt['commands'] = result.fetch(:commands).map do |command|
        { 'operation' => command.fetch(:operation).to_s, 'native_exit' => command[:native_exit],
          'success' => command.fetch(:success) }
      end
      receipt['native_exit'] = result[:native_exit]
      record['target_tree'] = @observation.tree(target) if phase == 'backup' && success
      # A lost completion receipt, or failed postcondition, leaves a started phase.
      if success
        @observation.copy_target!(target, record.fetch('target_tree')) if phase == 'mount'
        @observation.target_unmounted!(target) if phase == 'unmount'
        if (phase == 'activate') && @observation.host.fetch('next_boot') != target
          raise 'Activation did not select the target'
        end
        raise 'Immutable root generation changed during phase' unless
          @observation.source(record.fetch('source').fetch('path'), record.fetch('release')) == record.fetch('source')
      end
      receipt['state'] = success ? 'complete' : 'failed'
      receipt['finished_at'] = now
      record['state'] = 'stopped' unless success
      save
    end

    def native_updater
      require_relative 'updater/rsync'
      Updater::Rsync.new(root_generation: record.fetch('source').fetch('path'))
    end

    def save
      record['updated_at'] = now
      @store.write(record.fetch('id'), record)
    end

    def now
      Time.now.utc.iso8601(6)
    end
  end
end
