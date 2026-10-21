# frozen_string_literal: true

require 'json'
require 'digest'

module Nest
  # Supplied collector evidence, not a collector or proof of physical UX.
  class AcceptanceEvidence
    LIMIT = 65_536
    GATES = %w[kernel root_var pools network_dns_trust normal_main_apply converged_repeat system_failures
               user_managers service_canaries].freeze
    SHA256 = /\A[0-9a-f]{64}\z/.freeze

    def self.read(path)
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        raise 'Evidence must be a bounded regular file' unless file.stat.file? && file.size <= LIMIT

        JSON.parse(file.read(LIMIT + 1))
      end
    end

    def self.validate!(data, record, host)
      keys!(data, %w[schema kind transaction_id release observed_boot_id host_identity_sha256 pool_guid shared_state
                     target_tree evidence_ref evidence_sha256 gates])
      expected = { 'schema' => 1, 'kind' => 'reset_acceptance_evidence', 'transaction_id' => record.fetch('id'),
                   'release' => record.fetch('release'), 'observed_boot_id' => host.fetch('boot_id'),
                   'host_identity_sha256' => Digest::SHA256.hexdigest(host.fetch('machine_id')),
                   'pool_guid' => host.fetch('pool_guid'), 'shared_state' => record.fetch('shared_state'),
                   'target_tree' => record.fetch('target_tree') }
      raise 'Acceptance evidence binding mismatch' unless expected.all? { |key, value| data[key] == value }
      raise 'Acceptance evidence too large' if JSON.generate(data).bytesize > LIMIT

      reference!(data)
      gates = data.fetch('gates')
      keys!(gates, GATES)
      gates.each { |name, gate| gate!(name, gate) }
      if gates['normal_main_apply']['evidence_ref'] == gates['converged_repeat']['evidence_ref']
        raise 'Normal main apply and converged repeat require distinct evidence references'
      end

      data
    end

    def self.keys!(data, keys)
      raise 'Invalid evidence fields' unless data.is_a?(Hash) && data.keys.sort == keys.sort
    end

    def self.reference!(data)
      ref = data['evidence_ref']
      raise 'Invalid evidence reference or digest' unless ref.is_a?(String) &&
                                                          ref.match?(%r{\A[a-zA-Z0-9][a-zA-Z0-9_.:/-]{0,255}\z}) &&
                                                          data['evidence_sha256'].is_a?(String) &&
                                                          SHA256.match?(data['evidence_sha256'])
    end

    def self.gate!(name, gate)
      extra = case name
              when 'normal_main_apply', 'converged_repeat' then %w[native_exit]
              when 'system_failures' then %w[availability inventory_complete failures]
              when 'user_managers' then %w[availability inventory_complete failures managers]
              else []
              end
      keys!(gate, %w[result evidence_ref evidence_sha256] + extra)
      raise "Required acceptance gate unavailable or failed: #{name}" unless gate['result'] == 'pass'

      reference!(gate)
      if name == 'user_managers'
        managers = gate['managers']
        raise 'Invalid operational user-manager inventory' unless managers.is_a?(Array) && managers.size <= 128

        managers.each do |manager|
          keys!(manager, %w[identity availability result evidence_ref evidence_sha256])
          unless manager['identity'].is_a?(String) && manager['identity'].match?(/\A[\w@.:-]{1,128}\z/) &&
                 manager['availability'] == 'available' && manager['result'] == 'pass'
            raise 'Operational user-manager bus unavailable or failed'
          end

          reference!(manager)
        end
        raise 'Duplicate operational user manager' unless managers.map { |m| m['identity'] }.uniq.size == managers.size
      end
      if extra.include?('native_exit')
        allowed = name == 'normal_main_apply' ? [0, 2] : [0]
        unless gate['native_exit'].is_a?(Integer) && allowed.include?(gate['native_exit'])
          raise "Invalid catalog outcome: #{name}"
        end
      end
      return unless extra.include?('failures')

      unless gate['availability'] == 'available' && gate['inventory_complete'] == true &&
             gate['failures'].is_a?(Array) && gate['failures'].size <= 128
        raise "Incomplete operational manager/failure inventory: #{name}"
      end

      gate['failures'].each do |failure|
        keys!(failure, %w[identity disposition evidence_ref evidence_sha256])
        unless failure['identity'].is_a?(String) && failure['identity'].match?(/\A[\w@.:-]{1,128}\z/) &&
               failure['disposition'] == 'explained_historical'
          raise 'Failure requires explicit historical disposition; do not clear counters'
        end

        reference!(failure)
      end
    end
  end
end
