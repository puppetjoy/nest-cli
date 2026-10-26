# frozen_string_literal: true

require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'fixtures/lifecycle_worker'

RSpec.describe Nest::UpdateTransaction, 'postboot lifecycle' do
  let(:store) { Nest::UpdateStore.new(File.join(@directory, 'state'), owner: Process.euid) }
  let(:observation) { LifecycleFixture::Observation.new(@directory) }
  let(:transaction) { described_class.new(store: store, observation: observation) }
  let(:release) { TransactionFixture::RELEASE }
  def evidence
    LifecycleFixture.evidence(store.read('cycle'), observation.host)
  end

  around do |example|
    Dir.mktmpdir('nest-lifecycle-') do |directory|
      @directory = directory
      Dir.mkdir(store.path, 0o700)
      File.write(File.join(directory, 'identity'), JSON.generate(LifecycleFixture.identity))
      transaction.prepare('cycle', release: release, root_generation: '/fixture/release',
                                   capacity_policy: TransactionFixture.capacity_policy(directory),
                                   updater: TransactionFixture::Updater.new(directory, store))
      example.run
    end
  end

  def change_identity
    path = File.join(@directory, 'identity')
    data = JSON.parse(File.read(path))
    yield data
    File.write(path, JSON.generate(data))
  end

  def boot
    change_identity do |data|
      data['host'].merge!('boot_id' => 'boot-two', 'current' => 'fixture/ROOT/B',
                          'current_tree' => data['target_tree'], 'alternate_tree' => data['prior_tree'],
                          'target' => 'fixture/ROOT/A')
    end
  end

  def accept
    boot
    transaction.accept('cycle', evidence: evidence)
  end

  def add_owned(name = 'temporary')
    data = store.read('cycle')
    candidate = LifecycleFixture.owned(data, name)
    data.fetch('owned_candidates') << candidate
    store.write('cycle', data)
    change_identity { |identity| identity['extras'][candidate['dataset']] = candidate['tree'] }
    candidate
  end

  def finalize_worker(env = {})
    Open3.capture3(env, RbConfig.ruby, '-I', File.expand_path('../lib', __dir__),
                   File.join(__dir__, 'fixtures/lifecycle_worker.rb'), @directory)
  end

  it 'retains acceptance, finalization and report compatibility for historical records without capacity' do
    data = store.read('cycle')
    data.delete('capacity')
    data.delete('clone_snapshot')
    store.write('cycle', data)
    expect(transaction.export('cycle')['state']).to eq('prepared')
    expect(accept['accepted']).to be(true)
    expect(transaction.finalize('cycle', cleanup: 'owned')['finalized']).to be(true)
    expect(transaction.export('cycle')).to include('schema' => 2, 'state' => 'finalized')
  end

  it 'retains old r2 accounting through acceptance and finalization without retrofitting its contract' do
    data = store.read('cycle')
    data.delete('clone_snapshot')
    data['capacity'].delete('accounting_contract')
    data['capacity']['checks'].each do |check|
      check['observations'].delete('accounting_contract')
      check['observations'].delete('clone_snapshot')
      check['observations_sha256'] = Digest::SHA256.hexdigest(JSON.generate(check['observations']))
    end
    store.write('cycle', data)
    historical = data['capacity']
    expect(transaction.export('cycle')['capacity']).to eq(historical)
    expect(accept['accepted']).to be(true)
    expect(transaction.finalize('cycle', cleanup: 'owned')['finalized']).to be(true)
    expect(transaction.export('cycle')['capacity']).to eq(historical)
  end

  it 'never treats prepare or a changed boot as acceptance' do
    expect { transaction.finalize('cycle', cleanup: 'owned') }.to raise_error(/requires accepted/)
    expect { transaction.accept('cycle', evidence: evidence) }.to raise_error(/Postboot/)
    boot
    expect(transaction.status('cycle')).to include('accepted' => false)
    expect { transaction.finalize('cycle', cleanup: 'owned', plan: true) }.to raise_error(/requires accepted/)
  end

  [0, 23, nil].each do |native_exit|
    it "preserves reboot outcome #{native_exit.inspect} through actual boot observation, acceptance and finalize" do
      allow(transaction).to receive(:reboot_command).and_return(native_exit)
      requested = transaction.reboot('cycle').fetch('reboot')
      expect(transaction.status('cycle')['observation']).to include(
        'boot_changed' => false, 'expected_target_booted' => false
      )
      expect { transaction.accept('cycle', evidence: evidence) }.to raise_error(/Postboot/)
      boot
      expect(transaction.status('cycle')['observation']).to include(
        'boot_changed' => true, 'expected_target_booted' => true, 'accepted' => false
      )
      expect(transaction.reboot('cycle', plan: true)).to include(
        'reboot_eligible' => false, 'reboot_reason' => 'already_booted'
      )
      expect { transaction.reboot('cycle') }.to raise_error(/already requested/)
      expect(transaction.accept('cycle', evidence: evidence)['reboot']).to eq(requested)
      expect(transaction.finalize('cycle', cleanup: 'owned')['reboot']).to eq(requested)
      expect(transaction.export('cycle')['reboot']).to eq(requested)
      data = store.read('cycle')
      data['reboot']['command'] = ['bad']
      store.write('cycle', data)
      expect { transaction.export('cycle') }.to raise_error(/reboot receipt/)
      expect { transaction.finalize('cycle', cleanup: 'owned') }.to raise_error(/reboot receipt/)
    end
  end

  %w[next rollback wrong_boot].each do |mismatch|
    it "refuses changed-boot eligibility with #{mismatch} rather than announcing a safe reboot" do
      boot
      change_identity do |data|
        data['host']['next_boot'] = 'fixture/ROOT/A' if mismatch == 'next'
        data['prior_tree'][0]['guid'] = '999' if mismatch == 'rollback'
        data['host']['current_tree'][0]['guid'] = '999' if mismatch == 'wrong_boot'
      end
      expect { transaction.reboot('cycle', plan: true) }.to raise_error(/identity mismatch/)
      expect { transaction.reboot('cycle') }.to raise_error(/identity mismatch/)
      expect(store.read('cycle')).not_to have_key('reboot')
    end
  end

  it 'reobserves installed policy immediately before intent and leaves no receipt on drift' do
    allow(observation).to receive(:policy).and_return(observation.policy, { 'cli_sha256' => 'changed' })
    expect(transaction).not_to receive(:reboot_command)
    expect { transaction.reboot('cycle') }.to raise_error(/installed CLI changed/)
    expect(store.read('cycle')).not_to have_key('reboot')
  end

  %w[next rollback source policy shared].each do |mismatch|
    it "refuses unsafe reboot status after reconnect with changed #{mismatch}" do
      allow(transaction).to receive(:reboot_command).and_return(0)
      transaction.reboot('cycle')
      boot
      change_identity do |data|
        data['host']['next_boot'] = 'fixture/ROOT/A' if mismatch == 'next'
        data['prior_tree'][0]['guid'] = '999' if mismatch == 'rollback'
        data['source']['guid'] = '999' if mismatch == 'source'
        data['policy']['cli_sha256'] = 'changed' if mismatch == 'policy'
        data['shared_state']['guid'] = '999' if mismatch == 'shared'
      end
      expect { transaction.status('cycle') }.to raise_error(StandardError)
      expect { transaction.reboot('cycle', plan: true) }.to raise_error(StandardError)
      expect { transaction.reboot('cycle') }.to raise_error(/already requested/)
    end
  end

  it 'does not launch when durable intent readback fails and refuses retry after reconnect' do
    allow(store).to receive(:write).and_wrap_original do |original, id, data|
      original.call(id, data)
      raise 'Fixture lost readback' if data.key?('reboot')
    end
    expect(transaction).not_to receive(:reboot_command)
    expect { transaction.reboot('cycle') }.to raise_error(/readback/)
    expect(store.read('cycle').dig('reboot', 'state')).to eq('intent')
    expect { transaction.reboot('cycle') }.to raise_error(/already requested/)
  end

  it 'does not report action success when completion fsync/readback fails after rename' do
    allow(transaction).to receive(:reboot_command).and_return(0)
    allow(store).to receive(:write).and_wrap_original do |original, id, data|
      original.call(id, data)
      raise 'Fixture completion fsync failure' if data.dig('reboot', 'state') == 'returned'
    end
    expect(transaction.reboot('cycle')['reboot_requested']).to be(true)
    expect(transaction.reboot_succeeded).to be(false)
    expect { transaction.reboot('cycle') }.to raise_error(/already requested/)
  end

  it 'accepts bound named gates then finalizes ordinary A/B without extra deletion or plan writes' do
    expect(store.read('cycle')['clone_snapshot']).to eq('nest-reset-cycle')
    expect(accept).to include('schema' => 2, 'accepted' => true, 'finalized' => false)
    before = File.binread(File.join(store.path, 'cycle.json'))
    File.unlink(File.join(store.path, '.lock'))
    preview = transaction.finalize('cycle', cleanup: 'owned', plan: true)
    expect(preview).to include('read_only' => true, 'candidates' => [])
    expect(File.exist?(File.join(store.path, '.lock'))).to be(false)
    expect(File.binread(File.join(store.path, 'cycle.json'))).to eq(before)
    expect(transaction.finalize('cycle', cleanup: 'owned')).to include(
      'state' => 'finalized', 'finalized' => true, 'clone_snapshot' => 'nest-reset-cycle'
    )
    finalized = File.binread(File.join(store.path, 'cycle.json'))
    expect(transaction.finalize('cycle', cleanup: 'owned')).to include('finalized' => true)
    expect(File.binread(File.join(store.path, 'cycle.json'))).to eq(finalized)
    expect(File.exist?(File.join(@directory, 'deletions'))).to be(false)
    expect(observation.values.fetch('extras')).to be_empty
    expect(transaction.accept('cycle', evidence: evidence)).to include('finalized' => true)
  end

  %w[prepared accepted].each do |state|
    it "blocks another destructive prepare while #{state}" do
      accept if state == 'accepted'
      updater = double('never run')
      expect(updater).not_to receive(:update)
      expect do
        transaction.prepare('second', release: release, root_generation: '/fixture/release', updater: updater)
      end.to raise_error(/unresolved/)
    end
  end

  it 'allows a new preparation only after finalize releases the previous alternate retention boundary' do
    accept
    transaction.finalize('cycle', cleanup: 'owned')
    updater = double('halt at write-ahead boundary')
    expect(updater).to receive(:update).and_raise('fixture stops before native backup')
    expect do
      transaction.prepare('second', release: release, root_generation: '/fixture/release', updater: updater,
                                    capacity_policy: TransactionFixture.capacity_policy(@directory))
    end.to raise_error(/fixture stops/)
    expect(store.read('second')['host']['current']).to eq('fixture/ROOT/B')
    expect(store.read('second')['clone_snapshot']).to eq('nest-reset-second')
    expect(store.read('cycle')['clone_snapshot']).to eq('nest-reset-cycle')
  end

  {
    'boot' => ->(d) { d['host']['boot_id'] = 'boot-one' },
    'current GUID' => ->(d) { d['host']['current_tree'][0]['guid'] = '999' },
    'next' => ->(d) { d['host']['next_boot'] = 'fixture/ROOT/A' },
    'rollback GUID' => ->(d) { d['prior_tree'][0]['guid'] = '999' },
    'pool' => ->(d) { d['host']['pool_guid'] = '999' },
    'machine' => ->(d) { d['host']['machine_id'] = '0' * 32 },
    'state' => ->(d) { d['shared_state']['guid'] = '999' }
  }.each do |name, mutation|
    it "refuses acceptance and finalize with changed #{name}" do
      accept
      change_identity(&mutation)
      expect { transaction.finalize('cycle', cleanup: 'owned') }.to raise_error(/identity|boot/i)
      expect { transaction.accept('cycle', evidence: evidence) }.to raise_error(/identity|boot|differs/i)
    end
  end

  %w[transaction_id release observed_boot_id pool_guid host_identity_sha256 evidence_sha256].each do |key|
    it "refuses mismatched evidence #{key}" do
      boot
      data = evidence
      data[key] = 'wrong'
      expect { transaction.accept('cycle', evidence: data) }.to raise_error(/binding|digest/)
      expect(store.read('cycle')['state']).to eq('prepared')
    end
  end

  Nest::AcceptanceEvidence::GATES.each do |gate|
    it "refuses missing, failed and unavailable #{gate}" do
      boot
      %w[missing failed unavailable].each do |failure|
        data = evidence
        if failure == 'missing'
          data['gates'].delete(gate)
        else
          data['gates'][gate]['result'] = failure
        end
        expect { transaction.accept('cycle', evidence: data) }.to raise_error(/evidence fields|gate unavailable/)
      end
    end
  end

  it 'requires complete operational user-bus inventory and distinct converged repeat' do
    boot
    data = evidence
    data['gates']['user_managers']['availability'] = 'unavailable'
    expect { transaction.accept('cycle', evidence: data) }.to raise_error(/Incomplete/)
    data = evidence
    data['gates']['converged_repeat']['native_exit'] = 2
    expect { transaction.accept('cycle', evidence: data) }.to raise_error(/catalog outcome/)
  end

  it 'retains explained historical failures with explicit references rather than clearing them' do
    boot
    data = evidence
    failure = { 'identity' => 'user-1000:example.service', 'disposition' => 'explained_historical',
                'evidence_ref' => 'private/journal-record', 'evidence_sha256' => 'd' * 64 }
    data['gates']['user_managers']['failures'] << failure
    data['gates']['user_managers']['failures'][0]['disposition'] = 'cleared'
    expect { transaction.accept('cycle', evidence: data) }.to raise_error(/historical disposition/)
    failure['disposition'] = 'explained_historical'
    expect(transaction.accept('cycle', evidence: data)['acceptance']['evidence']).to eq(data)
  end

  it 'keeps historical schema-1 reports readable but refuses unsupported transitions' do
    expect(transaction.export('cycle')).to include('schema' => 1, 'accepted' => false)
    data = store.read('cycle')
    data['schema'] = 3
    store.write('cycle', data)
    expect { transaction.export('cycle') }.to raise_error(/Invalid transaction/)
    data['schema'] = 1
    data['state'] = 'accepted'
    store.write('cycle', data)
    expect { transaction.export('cycle') }.to raise_error(/Unsupported schema/)
  end

  it 'refuses resumed preparation after acceptance and cannot replace acceptance evidence' do
    accept
    expect do
      transaction.prepare('cycle', release: nil, root_generation: nil, resume: true)
    end.to raise_error(/cannot resume/)
    data = evidence
    data['evidence_ref'] = 'another/ref'
    expect { transaction.accept('cycle', evidence: data) }.to raise_error(/never replace/)
  end

  %w[A B].each do |name|
    it "refuses ordinary #{name} even with a fabricated ownership row" do
      accept
      add_owned(name)
      expect { transaction.finalize('cycle', cleanup: 'owned') }.to raise_error(%r{ordinary A/B})
    end
  end

  it 'refuses unrelated, renamed, GUID-changed, unsafe or inexplicably absent extras' do
    accept
    candidate = add_owned
    data = store.read('cycle')
    data['owned_candidates'][0]['creation']['transaction_id'] = 'unrelated'
    store.write('cycle', data)
    expect { transaction.finalize('cycle', cleanup: 'owned') }.to raise_error(/provenance/)
    data['owned_candidates'][0] = candidate
    store.write('cycle', data)
    change_identity { |d| d['extras'][candidate['dataset']][0]['guid'] = '999' }
    expect { transaction.finalize('cycle', cleanup: 'owned') }.to raise_error(/GUID changed/)
    change_identity do |d|
      d['extras'][candidate['dataset']] = candidate['tree']
      d['unsafe_extra'] = true
    end
    expect { transaction.finalize('cycle', cleanup: 'owned') }.to raise_error(/Mounted, held or dependent/)
    change_identity { |d| d['extras'].clear }
    expect { transaction.finalize('cycle', cleanup: 'owned') }.to raise_error(/absent without/)
  end

  %w[NEST_FIXTURE_CRASH_DELETE NEST_FIXTURE_CRASH_FINALIZE].each do |boundary|
    it "recovers exact cleanup after actual SIGKILL at #{boundary} without extra deletion" do
      accept
      candidate = add_owned
      _out, _err, status = finalize_worker(boundary => 'yes')
      expect(status.termsig).to eq(Signal.list.fetch('KILL'))
      receipt = store.read('cycle')['cleanup_receipts'].first
      expect(receipt['tree']).to eq(candidate['tree'])
      out, err, status = finalize_worker
      expect(status.success?).to be(true), err
      expect(JSON.parse(out)).to include('finalized' => true)
      out, err, status = finalize_worker
      expect(status.success?).to be(true), err
      expect(JSON.parse(out)).to include('finalized' => true)
      expect(File.readlines(File.join(@directory, 'deletions'), chomp: true)).to eq([candidate['dataset']])
    end
  end

  it 'refuses a reappeared completed candidate on repeat and never deletes its replacement' do
    accept
    candidate = add_owned
    transaction.finalize('cycle', cleanup: 'owned')
    change_identity { |data| data['extras'][candidate['dataset']] = candidate['tree'] }
    expect { transaction.finalize('cycle', cleanup: 'owned') }.to raise_error(/reappeared/)
    expect(File.readlines(File.join(@directory, 'deletions')).size).to eq(1)
  end

  it 'exports schema-2 history after subsequent BE replacement without pretending status is current' do
    accept
    transaction.finalize('cycle', cleanup: 'owned')
    change_identity { |data| data['target_tree'][0]['guid'] = '999' }
    expect(transaction.export('cycle')).to include('schema' => 2, 'accepted' => true, 'finalized' => true)
    expect { transaction.status('cycle') }.to raise_error(/identity mismatch/)
  end

  it 'refuses a changed recorded release and unsupported lifecycle schema downgrade' do
    accept
    data = store.read('cycle')
    data['release'] = "sha256:#{'f' * 64}"
    store.write('cycle', data)
    expect { transaction.finalize('cycle', cleanup: 'owned') }.to raise_error(/binding mismatch/)
    data['schema'] = 1
    store.write('cycle', data)
    expect { transaction.export('cycle') }.to raise_error(/schema 1 lifecycle/)
  end

  it 'refuses unavailable operational buses even when the aggregate gate says pass' do
    boot
    data = evidence
    data['gates']['user_managers']['managers'][0]['availability'] = 'unavailable'
    expect { transaction.accept('cycle', evidence: data) }.to raise_error(/bus unavailable/)
    data = evidence
    data['gates']['converged_repeat']['evidence_ref'] = data['gates']['normal_main_apply']['evidence_ref']
    expect { transaction.accept('cycle', evidence: data) }.to raise_error(/distinct evidence/)
  end

  it 'refuses oversized, nonregular, symlink and unknown-field evidence' do
    path = File.join(@directory, 'evidence.json')
    File.write(path, ' ' * (Nest::AcceptanceEvidence::LIMIT + 1))
    expect { Nest::AcceptanceEvidence.read(path) }.to raise_error(/bounded regular file/)
    link = File.join(@directory, 'evidence-link')
    File.symlink(path, link)
    expect { Nest::AcceptanceEvidence.read(link) }.to raise_error(Errno::ELOOP)
    boot
    data = evidence.merge('accepted' => true)
    expect { transaction.accept('cycle', evidence: data) }.to raise_error(/Invalid evidence fields/)
  end

  it 'checks the published JSON schema names and field sets against the supplied collector fixture' do
    schema = JSON.parse(File.read(File.expand_path('../docs/reset-acceptance-evidence.schema.json', __dir__)))
    expect(schema['required'].sort).to eq(evidence.keys.sort)
    expect(schema['properties']['gates']['required']).to match_array(Nest::AcceptanceEvidence::GATES)
    evidence['gates'].each do |name, gate|
      expect(schema['properties']['gates']['properties'][name]['required'].sort).to eq(gate.keys.sort)
    end
  end

  it 'uses the same real process flock for finalize' do
    accept
    store.lock do
      _out, err, status = finalize_worker
      expect(status.exitstatus).to eq(7)
      expect(err).to include('Another reset transaction is running')
    end
  end

  it 'rechecks safety after deletion intent and before native mutation' do
    accept
    add_owned
    allow(store).to receive(:write).and_wrap_original do |method, *args|
      method.call(*args)
      change_identity { |d| d['host']['next_boot'] = 'fixture/ROOT/A' } if args[1]['cleanup_receipts'].any?
    end
    expect { transaction.finalize('cycle', cleanup: 'owned') }.to raise_error(/identity mismatch/)
    expect(File.exist?(File.join(@directory, 'deletions'))).to be(false)
  end
end
