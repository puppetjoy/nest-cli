# frozen_string_literal: true

# Disposable-filesystem fixture only. Never instantiates a native updater or ZFS writer.
require 'nest/update_transaction'

module TransactionFixture
  RELEASE = "sha256:#{'a' * 64}"

  def self.capacity_policy(directory)
    path = File.join(directory, 'capacity-policy.json')
    unless File.exist?(path)
      File.write(path, JSON.generate(
                         'schema' => 1, 'kind' => 'nest_reset_capacity_policy', 'release' => RELEASE,
                         'hostname' => 'fixture', 'host_identity_sha256' => Digest::SHA256.hexdigest('f' * 32),
                         'pool_guid' => '101', 'source_guid' => '301', 'write_budget_bytes' => 1000,
                         'promotion_budget_bytes' => 1000, 'physical_reserve_bytes' => 100, 'slop_reserve_bytes' => 100
                       ))
    end
    path
  end

  class Observation
    attr_reader :directory

    def initialize(directory)
      @directory = directory
    end

    def values
      JSON.parse(File.read(File.join(directory, 'identity')))
    end

    def shared_state(_path)
      values.fetch('shared_state')
    end

    def host
      values.fetch('host')
    end

    def source(_path, release)
      raise 'Release mismatch' unless release == RELEASE

      values.fetch('source')
    end

    def policy
      values.fetch('policy')
    end

    # Native accounting is independently exercised by CapacityAdmission fixtures.
    def capacity(policy, host, _source, stage: 'backup')
      raise 'Fixture accounting changed' if values['capacity_denied']

      parts = host.fetch('current').split('/')
      names = (1...parts.size).map { |n| parts.take(n).join('/') }
      names.select! { |name| host.fetch('target').start_with?("#{name}/") }
      ancestors = names.each_with_index.to_h do |name, index|
        [name, { 'guid' => (100 + index).to_s, 'quota' => 0, 'refquota' => 0,
                 'used' => 100, 'referenced' => 100, 'available' => 10_000_000 }]
      end
      observations = { 'stage' => stage, 'accounting_contract' => Nest::CapacityAdmission::ACCOUNTING_CONTRACT,
                       'shared_ancestors' => ancestors, 'datasets' => ancestors }
      { 'admission' => 'admitted', 'admitted' => true, 'observations' => observations,
        'observations_sha256' => Digest::SHA256.hexdigest(JSON.generate(observations)),
        'policy_sha256' => Nest::CapacityPolicy.digest(policy) }
    end

    def tree(_target)
      values.fetch('target_tree')
    end

    def target_unmounted!(_target)
      raise 'Target mounted unexpectedly' if values['mounted']
    end

    def copy_target!(_target, expected)
      raise 'Mounted destination identity mismatch' unless values['mounted'] && tree(nil) == expected
    end
  end

  class Updater
    attr_reader :report

    def initialize(directory, store)
      @directory = directory
      @store = store
    end

    def update(phase, _stop, **_options)
      # Verify the actual on-disk write-ahead receipt before simulating an effect.
      receipt = @store.read('cycle')
      raise 'Side effect without a durable intent' unless receipt.fetch('phases').last.slice('phase', 'state') ==
                                                          { 'phase' => phase.to_s, 'state' => 'started' }

      File.open(File.join(@directory, 'effects'), 'a') { |file| file.puts(phase) }
      path = File.join(@directory, 'identity')
      identity = JSON.parse(File.read(path))
      identity['mounted'] = true if phase == :mount
      identity['mounted'] = false if phase == :unmount
      identity['host']['next_boot'] = identity['host']['target'] if phase == :activate
      File.write(path, JSON.generate(identity))
      if ENV['NEST_FIXTURE_CRASH'] == phase.to_s
        # SIGKILL means no Ruby ensure/rescue can manufacture completion.
        Process.kill('KILL', Process.pid)
      end
      success = ENV['NEST_FIXTURE_FAIL'] != phase.to_s
      @report = { commands: [{ operation: :copy, native_exit: success ? 0 : 23, success: success }],
                  native_exit: success ? nil : 23,
                  error: 'SECRET MUST NOT BE SERIALIZED', output: 'SECRET MUST NOT BE SERIALIZED' }
      success
    end
  end

  class Store < Nest::UpdateStore
    def write(id, data)
      super
      last = data.fetch('phases').last
      return unless last && last['state'] == 'complete' && ENV['NEST_FIXTURE_CRASH_RECEIPT'] == last['phase']

      Process.kill('KILL', Process.pid)
    end
  end

  def self.run(directory, mode)
    store = Store.new(File.join(directory, 'state'), owner: Process.euid)
    transaction = Nest::UpdateTransaction.new(store: store, observation: Observation.new(directory))
    result = if mode == 'status'
               transaction.status('cycle')
             else
               transaction.prepare('cycle', release: RELEASE, root_generation: '/fixture/release',
                                            capacity_policy: mode == 'resume' ? nil : capacity_policy(directory),
                                            resume: mode == 'resume', updater: Updater.new(directory, store))
             end
    puts JSON.generate(result)
  rescue StandardError => e
    warn e.message
    exit 7
  end
end

TransactionFixture.run(*ARGV) if $PROGRAM_NAME == __FILE__
