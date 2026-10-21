# frozen_string_literal: true

require_relative 'transaction_worker'

module LifecycleFixture
  def self.identity
    a = [{ 'dataset' => 'fixture/ROOT/A', 'guid' => '201', 'mountpoint' => '/' }]
    b = [{ 'dataset' => 'fixture/ROOT/B', 'guid' => '501', 'mountpoint' => '/' }]
    { 'host' => { 'machine_id' => 'f' * 32, 'hostname' => 'fixture', 'boot_id' => 'boot-one', 'pool_guid' => '101',
                  'current' => 'fixture/ROOT/A', 'current_tree' => a, 'alternate_tree' => b,
                  'target' => 'fixture/ROOT/B', 'next_boot' => 'fixture/ROOT/A' },
      'source' => { 'path' => '/fixture/release', 'guid' => '301', 'release' => TransactionFixture::RELEASE },
      'shared_state' => { 'dataset' => 'fixture/updates', 'guid' => '401', 'pool_guid' => '101' },
      'policy' => { 'filter_sha256' => 'filter', 'cli_sha256' => 'cli' },
      'target_tree' => b, 'prior_tree' => a, 'extras' => {}, 'mounted' => false }
  end

  def self.evidence(record, host)
    gates = Nest::AcceptanceEvidence::GATES.to_h do |name|
      gate = { 'result' => 'pass', 'evidence_ref' => "fixture/#{name}", 'evidence_sha256' => 'b' * 64 }
      gate['native_exit'] = name == 'normal_main_apply' ? 2 : 0 if %w[normal_main_apply converged_repeat].include?(name)
      if %w[system_failures user_managers].include?(name)
        gate.merge!('availability' => 'available', 'inventory_complete' => true, 'failures' => [])
      end
      if name == 'user_managers'
        gate['managers'] = [{ 'identity' => 'user-1000', 'availability' => 'available', 'result' => 'pass',
                              'evidence_ref' => 'fixture/user-1000', 'evidence_sha256' => 'e' * 64 }]
      end
      [name, gate]
    end
    { 'schema' => 1, 'kind' => 'reset_acceptance_evidence', 'transaction_id' => record.fetch('id'),
      'release' => record.fetch('release'), 'observed_boot_id' => host.fetch('boot_id'),
      'host_identity_sha256' => Digest::SHA256.hexdigest(host.fetch('machine_id')),
      'pool_guid' => host.fetch('pool_guid'),
      'shared_state' => record.fetch('shared_state'), 'target_tree' => record.fetch('target_tree'),
      'evidence_ref' => 'fixture/acceptance', 'evidence_sha256' => 'c' * 64, 'gates' => gates }
  end

  # Only fixture creation writes this shape. Production preparation makes no extra.
  def self.owned(record, name = 'temporary')
    dataset = "fixture/ROOT/#{name}"
    tree = [{ 'dataset' => dataset, 'guid' => '601', 'mountpoint' => '/' }]
    { 'dataset' => dataset, 'tree' => tree,
      'creation' => { 'transaction_id' => record.fetch('id'), 'operation' => 'create_extra', 'state' => 'complete',
                      'tree' => tree, 'created_at' => Time.now.utc.iso8601(6) } }
  end

  class Observation < TransactionFixture::Observation
    def tree(target)
      target == 'fixture/ROOT/A' ? values.fetch('prior_tree') : super
    end

    def cleanup_tree(dataset, _expected)
      values.fetch('extras')[dataset]
    end

    def cleanup_safe!(_dataset)
      raise 'Mounted, held or dependent candidate' if values['unsafe_extra']
    end

    def destroy_owned!(dataset, expected, host:)
      raise 'Host changed' unless self.host == host

      raise 'Incorrect destroy identity' unless cleanup_tree(dataset, expected) == expected

      File.open(File.join(directory, 'deletions'), 'a') { |file| file.puts(dataset) }
      path = File.join(directory, 'identity')
      data = values
      data.fetch('extras').delete(dataset)
      File.write(path, JSON.generate(data))
      Process.kill('KILL', Process.pid) if ENV['NEST_FIXTURE_CRASH_DELETE'] == 'yes'
    end
  end

  class Store < Nest::UpdateStore
    def write(id, data)
      super
      return unless ENV['NEST_FIXTURE_CRASH_FINALIZE'] == 'yes' && data['state'] == 'finalizing'
      return unless data['cleanup_receipts'].any? { |r| r['state'] == 'complete' }

      Process.kill('KILL', Process.pid)
    end
  end

  def self.run(directory)
    store = Store.new(File.join(directory, 'state'), owner: Process.euid)
    transaction = Nest::UpdateTransaction.new(store: store, observation: Observation.new(directory))
    puts JSON.generate(transaction.finalize('cycle', cleanup: 'owned'))
  rescue StandardError => e
    warn e.message
    exit 7
  end
end

LifecycleFixture.run(*ARGV) if $PROGRAM_NAME == __FILE__
