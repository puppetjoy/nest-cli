# frozen_string_literal: true

require 'tmpdir'
require_relative 'fixtures/lifecycle_worker'

RSpec.describe Nest::UpdateTransaction, 'explicit postboot policy' do
  let(:store) { Nest::UpdateStore.new(File.join(@directory, 'state'), owner: Process.euid) }
  let(:observation) { LifecycleFixture::Observation.new(@directory) }
  let(:transaction) { described_class.new(store: store, observation: observation) }
  let(:policy) { { 'filter_sha256' => 'd' * 64, 'cli_sha256' => 'e' * 64 } }

  around do |example|
    Dir.mktmpdir('nest-policy-') do |directory|
      @directory = directory
      Dir.mkdir(store.path, 0o700)
      File.write(File.join(directory, 'identity'), JSON.generate(LifecycleFixture.identity))
      transaction.prepare('cycle', release: TransactionFixture::RELEASE, root_generation: '/fixture/release',
                                   capacity_policy: TransactionFixture.capacity_policy(directory),
                                   updater: TransactionFixture::Updater.new(directory, store))
      @original = store.read('cycle')
      example.run
    end
  end

  def change
    data = observation.values
    yield data
    File.write(File.join(@directory, 'identity'), JSON.generate(data))
  end

  def boot(receipt: true, outcome: 0)
    if receipt
      allow(transaction).to receive(:reboot_command).and_return(outcome)
      transaction.reboot('cycle')
    end
    change do |data|
      data['host'].merge!('boot_id' => 'boot-two', 'current' => 'fixture/ROOT/B',
                          'current_tree' => data['target_tree'], 'alternate_tree' => data['prior_tree'],
                          'target' => 'fixture/ROOT/A')
      data['policy'] = policy
    end
  end

  def context
    data = store.read('cycle')
    { 'schema' => 1, 'kind' => 'reset_postboot_policy', 'transaction_id' => 'cycle',
      'release' => data['release'], 'observed_boot_id' => observation.host['boot_id'],
      'host_identity_sha256' => Digest::SHA256.hexdigest(data['host']['machine_id']),
      'pool_guid' => data['host']['pool_guid'], 'shared_state' => data['shared_state'],
      'target_tree' => data['target_tree'], 'source' => data['source'], 'original_policy' => data['policy'],
      'current_policy' => policy, 'evidence_ref' => 'fixture/review', 'evidence_sha256' => 'a' * 64 }
  end

  def evidence
    LifecycleFixture.evidence(store.read('cycle'), observation.host)
  end

  def accept(context = self.context, report = evidence)
    transaction.accept('cycle', evidence: report, postboot_policy: context)
  end

  def bytes
    File.binread(File.join(store.path, 'cycle.json'))
  end

  def originals_unchanged
    retained = store.read('cycle')
    %w[host source policy phases capacity created_at clone_snapshot target_tree shared_state].each do |key|
      expect(retained[key]).to eq(@original[key])
    end
  end

  it 'reports drift before and after reboot without journal or lock writes' do
    boot
    before = bytes
    File.unlink(File.join(store.path, '.lock'))
    result = transaction.status('cycle')
    expect(result['policy']).to eq(@original['policy'])
    expect(result['identity_observation']).to include('policy' => policy, 'policy_matches_original' => false,
                                                     'source_matches_original' => true)
    expect(result['accepted']).to be(false)
    expect(File.exist?(File.join(store.path, '.lock'))).to be(false)
    expect(bytes).to eq(before)
  end

  it 'reports unknown source and policy truthfully without granting admission' do
    boot
    allow(observation).to receive(:source).and_raise('unavailable')
    allow(observation).to receive(:policy).and_raise('unavailable')
    before = bytes
    expect(transaction.status('cycle')['identity_observation']).to eq(
      'source' => nil, 'policy' => nil, 'source_matches_original' => nil, 'policy_matches_original' => nil
    )
    expect { accept }.to raise_error(/unavailable/)
    expect(bytes).to eq(before)
  end

  [0, 23, nil].each do |outcome|
    it "retains literal reboot outcome #{outcome.inspect} after proven target boot and idempotent finalize" do
      boot(outcome: outcome)
      reboot = store.read('cycle')['reboot']
      retained_context = context
      report = evidence
      expect(accept(retained_context, report)['acceptance']['postboot_policy']).to eq(retained_context)
      before = bytes
      File.unlink(File.join(store.path, '.lock'))
      expect(transaction.finalize('cycle', cleanup: 'owned', plan: true)['candidates']).to eq([])
      expect(File.exist?(File.join(store.path, '.lock'))).to be(false)
      expect(bytes).to eq(before)
      expect(transaction.finalize('cycle', cleanup: 'owned')['finalized']).to be(true)
      finalized = bytes
      expect(transaction.finalize('cycle', cleanup: 'owned')['finalized']).to be(true)
      expect(accept(retained_context, report)['finalized']).to be(true)
      expect(bytes).to eq(finalized)
      expect(transaction.export('cycle')['reboot']).to eq(reboot)
      expect(File.exist?(File.join(@directory, 'deletions'))).to be(false)
      originals_unchanged
    end
  end

  it 'requires explicit context and forbids reset/reboot replay under drift' do
    boot
    before = bytes
    expect(transaction).not_to receive(:reboot_command)
    expect do
      transaction.prepare('cycle', resume: true, release: nil, root_generation: nil)
    end.to raise_error(/replay/)
    expect { transaction.reboot('cycle') }.to raise_error(/already requested/)
    expect { transaction.reboot('cycle', plan: true) }.to raise_error(/installed CLI changed/)
    expect { transaction.accept('cycle', evidence: evidence) }.to raise_error(/installed CLI changed/)
    expect(bytes).to eq(before)
  end

  it 'keeps preboot status read-only but refuses drifted preparation, reboot and acceptance' do
    change { |data| data['policy'] = policy }
    before = bytes
    expect(transaction.status('cycle')['identity_observation']['policy_matches_original']).to be(false)
    expect { transaction.reboot('cycle') }.to raise_error(/installed CLI changed/)
    expect { transaction.reboot('cycle', plan: true) }.to raise_error(/installed CLI changed/)
    expect do
      transaction.prepare('cycle', resume: true, release: nil, root_generation: nil)
    end.to raise_error(/installed CLI changed/)
    expect { accept }.to raise_error(/Postboot/)
    expect(bytes).to eq(before)
  end

  it 'rejects missing reboot provenance despite a changed target boot' do
    boot(receipt: false)
    before = bytes
    expect { accept }.to raise_error(/proven reboot/)
    expect(bytes).to eq(before)
  end

  %w[boot next host pool shared target rollback source].each do |mismatch|
    it "refuses wrong #{mismatch} identity with no acceptance write" do
      boot
      retained_context = context
      change do |data|
        data['host']['boot_id'] = '' if mismatch == 'boot'
        data['host']['next_boot'] = 'fixture/ROOT/A' if mismatch == 'next'
        data['host']['hostname'] = 'other' if mismatch == 'host'
        data['host']['pool_guid'] = '999' if mismatch == 'pool'
        data['shared_state']['guid'] = '999' if mismatch == 'shared'
        data['host']['current_tree'][0]['guid'] = '999' if mismatch == 'target'
        data['prior_tree'][0]['guid'] = '999' if mismatch == 'rollback'
        data['source']['guid'] = '999' if mismatch == 'source'
      end
      before = bytes
      expect { accept(retained_context) }.to raise_error(StandardError)
      expect(bytes).to eq(before)
    end
  end

  %w[transaction_id release observed_boot_id pool_guid shared_state target_tree source original_policy
     current_policy evidence_sha256 extra].each do |field|
    it "rejects invalid policy evidence field #{field}" do
      boot
      invalid = context.merge(field => 'bad')
      before = bytes
      expect { accept(invalid) }.to raise_error(StandardError)
      expect(bytes).to eq(before)
    end
  end

  it 'rejects incomplete, ambiguous and contradictory original preparation receipts' do
    boot
    original = store.read('cycle')
    %w[started failed].each do |state|
      data = Marshal.load(Marshal.dump(original))
      data['phases'].last['state'] = state
      store.write('cycle', data)
      before = bytes
      expect { accept }.to raise_error(StandardError)
      expect(bytes).to eq(before)
    end
    data = Marshal.load(Marshal.dump(original))
    data['phases'].last['commands'][0]['success'] = false
    store.write('cycle', data)
    expect { accept }.to raise_error(/failed command/)
  end

  it 'does not let policy evidence waive actual acceptance report validation' do
    boot
    invalid = evidence
    invalid['gates']['converged_repeat']['native_exit'] = 2
    before = bytes
    expect { accept(context, invalid) }.to raise_error(/catalog outcome/)
    invalid = evidence
    invalid['gates']['system_failures']['result'] = 'fail'
    expect { accept(context, invalid) }.to raise_error(/unavailable or failed/)
    expect(bytes).to eq(before)
  end

  it 'reobserves policy immediately before acceptance and never silently refreshes it later' do
    boot
    retained_context = context
    allow(observation).to receive(:policy).and_return(policy, policy.merge('cli_sha256' => 'f' * 64))
    before = bytes
    expect { accept(retained_context) }.to raise_error(/installed policy changed/)
    expect(bytes).to eq(before)
  end

  it 'refuses changed current policy at finalize and context replacement at acceptance retry' do
    boot
    retained_context = context
    report = evidence
    accept(retained_context, report)
    change { |data| data['policy']['cli_sha256'] = 'f' * 64 }
    before = bytes
    expect { transaction.finalize('cycle', cleanup: 'owned') }.to raise_error(/installed policy changed/)
    expect { transaction.finalize('cycle', cleanup: 'owned', plan: true) }.to raise_error(/installed policy changed/)
    expect { accept(retained_context, report) }.to raise_error(/installed policy changed/)
    expect { accept(context.merge('current_policy' => observation.policy), report) }.to raise_error(/never replace/)
    expect(bytes).to eq(before)
  end

  it 'forbids owned deletion in the evolved lane even with otherwise valid ownership' do
    boot
    accept
    data = store.read('cycle')
    candidate = LifecycleFixture.owned(data)
    data['owned_candidates'] << candidate
    store.write('cycle', data)
    change { |identity| identity['extras'][candidate['dataset']] = candidate['tree'] }
    before = bytes
    expect { transaction.finalize('cycle', cleanup: 'owned') }.to raise_error(/non-deleting/)
    expect(bytes).to eq(before)
    expect(File.exist?(File.join(@directory, 'deletions'))).to be(false)
  end
end
