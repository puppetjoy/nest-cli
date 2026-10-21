# frozen_string_literal: true

require_relative 'acceptance_evidence'

module Nest
  # Narrow postboot lifecycle under the same host lock as preparation.
  module UpdateLifecycle
    def accept(id, evidence:)
      @store.lock do
        @record = load_record(id)
        if %w[accepted finalizing finalized].include?(record['state'])
          observed = accepted_host!
          unless record.fetch('acceptance').fetch('evidence') == evidence &&
                 record['acceptance']['boot_id'] == observed['boot_id']
            raise 'Recorded acceptance differs; never replace its evidence'
          end

          return report
        end
        raise 'Only a prepared transaction can be accepted' unless record['state'] == 'prepared'

        observed = accepted_host!
        AcceptanceEvidence.validate!(evidence, record, observed)
        raise 'Host observation changed during acceptance' unless accepted_host! == observed

        record['schema'] = 2 # Explicit schema-1 prepared -> schema-2 accepted transition only.
        record['acceptance'] = { 'recorded_at' => now, 'boot_id' => observed.fetch('boot_id'), 'evidence' => evidence }
        record['owned_candidates'] = [] # Normal native preparation creates no extra BE.
        record['cleanup_receipts'] = []
        record['state'] = 'accepted'
        save
        report
      end
    end

    def finalize(id, cleanup:, plan: false)
      raise 'Only --cleanup=owned is supported' unless cleanup == 'owned'

      operation = lambda do
        @record = load_record(id)
        raise 'Finalize requires accepted state' unless %w[accepted finalizing finalized].include?(record['state'])

        observed = accepted_host!
        raise 'Acceptance boot changed' unless observed['boot_id'] == record.fetch('acceptance').fetch('boot_id')

        candidates = record.fetch('owned_candidates')
        candidates.each { |candidate| cleanup_identity!(candidate, observed, plan: plan) }
        if plan
          return report.merge('read_only' => true, 'cleanup' => 'owned', 'candidates' => candidates,
                              'snapshot_policy' => 'retain_origins_no_reclamation_claim')
        end
        return report if record['state'] == 'finalized'

        record['state'] = 'finalizing'
        save
        candidates.each { |candidate| cleanup_candidate(candidate, observed) }
        raise 'Boot selection changed during finalize' unless accepted_host! == observed

        record['state'] = 'finalized'
        record['finalized_at'] = now
        save
        report
      end
      plan ? operation.call : @store.lock(&operation)
    end

    private

    def accepted_host!
      observed = bound_host!
      baseline = record.fetch('host')
      unless observed['boot_id'] != baseline['boot_id'] && observed['current'] == baseline['target'] &&
             observed['next_boot'] == baseline['target'] && observed['current_tree'] == record['target_tree'] &&
             observed['target'] == baseline['current'] && observed['alternate_tree'] == baseline['current_tree'] &&
             @observation.tree(baseline.fetch('current')) == baseline.fetch('current_tree')
        raise 'Postboot current, next, boot or rollback GUID identity mismatch'
      end

      observed
    end

    def validate_lifecycle!(data)
      if data['schema'] == 1
        raise 'Unsupported schema 1 lifecycle state' unless %w[pending stopped prepared].include?(data['state'])

        fields = %w[acceptance owned_candidates cleanup_receipts finalized_at]
        raise 'Schema 1 cannot contain lifecycle fields' if fields.any? { |key| data.key?(key) }

        return
      end
      raise 'Unsupported lifecycle schema transition' unless %w[accepted finalizing finalized].include?(data['state'])

      acceptance = data.fetch('acceptance')
      host = data.fetch('host').merge('boot_id' => acceptance.fetch('boot_id'))
      raise 'Acceptance must bind a changed boot' if host['boot_id'] == data['host']['boot_id']

      AcceptanceEvidence.keys!(acceptance, %w[recorded_at boot_id evidence])
      Time.iso8601(acceptance.fetch('recorded_at'))
      AcceptanceEvidence.validate!(acceptance.fetch('evidence'), data, host)
      # No extra is created by the current preparer. Reserved ownership records must
      # originate in a future source-owned creation phase, never user-supplied names.
      candidates = data.fetch('owned_candidates')
      receipts = data.fetch('cleanup_receipts')
      raise 'Invalid owned cleanup inventory' unless candidates.is_a?(Array) && candidates.size <= 16 &&
                                                     receipts.is_a?(Array) && receipts.size <= candidates.size

      candidates.each { |candidate| validate_ownership!(candidate, data) }
      raise 'Duplicate cleanup identity' unless candidates.map { |c| c['dataset'] }.uniq.size == candidates.size

      receipts.each do |receipt|
        fields = %w[dataset tree state started_at]
        fields << 'finished_at' if receipt['state'] == 'complete'
        AcceptanceEvidence.keys!(receipt, fields)
        Time.iso8601(receipt.fetch('started_at'))
        Time.iso8601(receipt.fetch('finished_at')) if receipt['state'] == 'complete'
        candidate = candidates.find { |c| c['dataset'] == receipt['dataset'] }
        raise 'Invalid cleanup receipt' unless candidate && receipt['tree'] == candidate['tree'] &&
                                               %w[started complete].include?(receipt['state'])
      end
      raise 'Duplicate cleanup receipt' unless receipts.map { |r| r['dataset'] }.uniq.size == receipts.size

      return unless data['state'] == 'finalized'

      Time.iso8601(data.fetch('finalized_at'))
      raise 'Incomplete finalized cleanup' unless receipts.size == candidates.size &&
                                                  receipts.all? { |r| r['state'] == 'complete' }
    end

    def validate_ownership!(candidate, data)
      AcceptanceEvidence.keys!(candidate, %w[dataset tree creation])
      creation = candidate.fetch('creation')
      AcceptanceEvidence.keys!(creation, %w[transaction_id operation state tree created_at])
      unless creation['transaction_id'] == data['id'] && creation['operation'] == 'create_extra' &&
             creation['state'] == 'complete' && creation['tree'] == candidate['tree']
        raise 'Missing transaction-owned creation provenance'
      end

      Time.iso8601(creation.fetch('created_at'))
      tree = candidate.fetch('tree')
      dataset = candidate.fetch('dataset')
      root = File.dirname(data.fetch('host').fetch('current'))
      unless dataset.is_a?(String) && dataset.match?(%r{\A#{Regexp.escape(root)}/[a-zA-Z0-9][a-zA-Z0-9_.:-]*\z}) &&
             !%w[A B].include?(dataset.split('/').last) && tree.is_a?(Array) && !tree.empty? && tree.size <= 128 &&
             tree.any? { |row| row['dataset'] == dataset } && tree.all? do |row|
               row.keys.sort == %w[dataset guid mountpoint] && row['guid'].is_a?(String) &&
               row['guid'].match?(/\A[1-9][0-9]*\z/) && row['mountpoint'].is_a?(String) &&
               (row['dataset'] == dataset || row['dataset'].start_with?("#{dataset}/"))
             end
        raise 'Invalid owned extra identity; ordinary A/B cannot be cleanup candidates'
      end
    end

    def cleanup_identity!(candidate, observed, plan: false)
      dataset = candidate.fetch('dataset')
      raise 'Refusing current or next BE cleanup' if [observed['current'], observed['next_boot']].include?(dataset)

      receipt = record.fetch('cleanup_receipts').find { |r| r['dataset'] == dataset }
      tree = @observation.cleanup_tree(dataset, candidate.fetch('tree'))
      if tree.nil?
        unless receipt && receipt['tree'] == candidate['tree']
          raise 'Owned candidate absent without exact deletion intent'
        end

        return :absent
      end
      raise 'Completed cleanup candidate reappeared' if receipt && receipt['state'] == 'complete'
      raise 'Cleanup candidate GUID changed' unless tree == candidate.fetch('tree')

      @observation.cleanup_safe!(dataset)
      raise 'Finalized transaction cannot delete again' if record['state'] == 'finalized' && !plan

      :present
    end

    def cleanup_candidate(candidate, observed)
      dataset = candidate.fetch('dataset')
      receipt = record.fetch('cleanup_receipts').find { |r| r['dataset'] == dataset }
      unless receipt
        receipt = { 'dataset' => dataset, 'tree' => candidate.fetch('tree'), 'state' => 'started', 'started_at' => now }
        record.fetch('cleanup_receipts') << receipt
        save
      end
      raise 'Safety observation changed before cleanup' unless accepted_host! == observed

      if cleanup_identity!(candidate, observed) == :present
        @observation.destroy_owned!(dataset, candidate.fetch('tree'), host: observed)
        remaining = @observation.cleanup_tree(dataset, candidate.fetch('tree'))
        raise 'Owned deletion did not remove exact tree' unless remaining.nil?
      end
      raise 'Boot selection changed during cleanup' unless accepted_host! == observed

      receipt['state'] = 'complete'
      receipt['finished_at'] = now
      save
    end
  end
end
