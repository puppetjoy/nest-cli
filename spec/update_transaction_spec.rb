# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'nest/update_transaction'
require_relative 'fixtures/transaction_worker'

RSpec.describe Nest::UpdateTransaction do
  let(:release) { TransactionFixture::RELEASE }
  let(:store) { Nest::UpdateStore.new(File.join(@directory, 'state'), owner: Process.euid) }
  let(:observation) { TransactionFixture::Observation.new(@directory) }
  let(:transaction) { described_class.new(store: store, observation: observation) }

  around do |example|
    Dir.mktmpdir('nest-transaction-') do |directory|
      @directory = directory
      Dir.mkdir(File.join(directory, 'state'), 0o700)
      File.write(File.join(directory, 'identity'), JSON.generate(
                                                     'host' => { 'machine_id' => 'f' * 32, 'hostname' => 'fixture',
                                                                 'boot_id' => 'boot-one', 'pool_guid' => '101',
                                                                 'current' => 'fixture/ROOT/A',
                                                                 'current_tree' => [
                                                                   { 'dataset' => 'fixture/ROOT/A', 'guid' => '201',
                                                                     'mountpoint' => '/' }
                                                                 ],
                                                                 'target' => 'fixture/ROOT/B',
                                                                 'next_boot' => 'fixture/ROOT/A' },
                                                     'source' => { 'path' => '/fixture/release', 'guid' => '301',
                                                                   'release' => release },
                                                     'shared_state' => { 'dataset' => 'fixture/updates',
                                                                         'guid' => '401', 'pool_guid' => '101' },
                                                     'policy' => { 'filter_sha256' => 'filter', 'cli_sha256' => 'cli' },
                                                     'target_tree' => [{ 'dataset' => 'fixture/ROOT/B', 'guid' => '501',
                                                                         'mountpoint' => '/' }],
                                                     'mounted' => false
                                                   ))
      example.run
    end
  end

  def worker(mode, crash: nil, crash_receipt: nil, fail_phase: nil)
    env = { 'NEST_FIXTURE_CRASH' => crash, 'NEST_FIXTURE_CRASH_RECEIPT' => crash_receipt,
            'NEST_FIXTURE_FAIL' => fail_phase }
    Open3.capture3(env, RbConfig.ruby, '-I', File.expand_path('../lib', __dir__),
                   File.join(__dir__, 'fixtures/transaction_worker.rb'), @directory, mode)
  end

  def change_identity
    path = File.join(@directory, 'identity')
    data = JSON.parse(File.read(path))
    yield data
    File.write(path, JSON.generate(data))
  end

  def effects
    File.readlines(File.join(@directory, 'effects'), chomp: true)
  end

  it 'persists each intent before the effect and retains a sanitized report after worker exit' do
    out, err, status = worker('new')
    expect(status.success?).to be(true), err
    report = JSON.parse(out)
    expect(report).to include('state' => 'prepared', 'success' => true, 'reboot_requested' => false)
    expect(report['phases'].map { |row| row['phase'] }).to eq(described_class::PHASES)
    expect(out).not_to include('SECRET', 'machine_id')
    expect(effects).to eq(described_class::PHASES)
    before = Dir.children(store.path).sort.to_h { |name| [name, File.binread(File.join(store.path, name))] }
    status_out, status_err, status = worker('status')
    expect(status.success?).to be(true), status_err
    expect(JSON.parse(status_out)['state']).to eq('prepared')
    expect(Dir.children(store.path).sort.to_h do |name|
      [name, File.binread(File.join(store.path, name))]
    end).to eq(before)
    expect(File.stat(File.join(store.path, 'cycle.json')).mode & 0o777).to eq(0o600)
  end

  %w[backup mount kernel unmount activate].each do |phase|
    it "never replays a SIGKILL at the #{phase} boundary" do
      _out, _err, status = worker('new', crash: phase)
      expect(status.termsig).to eq(Signal.list.fetch('KILL'))
      expect(store.read('cycle')['phases'].last).to include('phase' => phase, 'state' => 'started')
      before = effects
      _out, err, status = worker('resume')
      expect(status.exitstatus).to eq(7)
      expect(err).to match(/Ambiguous|Next boot selection/)
      expect(effects).to eq(before)
    end
  end

  it 'resumes only the interrupted copy, never backup/mount, and then completes remaining phases' do
    worker('new', crash: 'sync')
    _out, err, status = worker('resume')
    expect(status.success?).to be(true), err
    expect(effects).to eq(%w[backup mount sync sync kernel unmount activate])
    expect(store.read('cycle')['phases'][2]).to include('attempt' => 2, 'state' => 'complete')
  end

  %w[sync activate].each do |phase|
    it "skips a completed #{phase} receipt after an actual worker crash" do
      _out, _err, status = worker('new', crash_receipt: phase)
      expect(status.termsig).to eq(Signal.list.fetch('KILL'))
      expect(store.read('cycle')['phases'].last).to include('phase' => phase, 'state' => 'complete')
      _out, err, status = worker('resume')
      expect(status.success?).to be(true), err
      expect(effects).to eq(described_class::PHASES)
    end
  end

  it 'retains the native failure and never enters kernel/activation after failed copy' do
    out, err, status = worker('new', fail_phase: 'sync')
    expect(status.success?).to be(true), err # Fixture returns the result; CLI maps failure to exit 2.
    report = JSON.parse(out)
    expect(report).to include('success' => false, 'state' => 'stopped')
    expect(report['phases'].last).to include('native_exit' => 23, 'state' => 'failed')
    expect(effects).to eq(%w[backup mount sync])
  end

  it 'exports historical receipts even when subsequent updates replace the old target GUID' do
    worker('new')
    change_identity { |data| data['target_tree'][0]['guid'] = '999' }
    expect { transaction.status('cycle') }.to raise_error(/target BE identity mismatch/)
    expect(transaction.export('cycle')).to include('state' => 'prepared')
    change_identity { |data| data['host']['pool_guid'] = '999' }
    expect { transaction.export('cycle') }.to raise_error(/Host or pool identity mismatch/)
  end

  {
    'machine ID' => ->(data) { data['host']['machine_id'] = 'other' },
    'hostname' => ->(data) { data['host']['hostname'] = 'other' },
    'boot ID' => ->(data) { data['host']['boot_id'] = 'boot-two' },
    'pool GUID' => ->(data) { data['host']['pool_guid'] = '999' },
    'current BE GUID' => ->(data) { data['host']['current_tree'][0]['guid'] = '999' },
    'target BE GUID' => ->(data) { data['target_tree'][0]['guid'] = '999' },
    'source generation' => ->(data) { data['source']['guid'] = '999' },
    'shared state GUID' => ->(data) { data['shared_state']['guid'] = '999' },
    'filter policy' => ->(data) { data['policy']['filter_sha256'] = 'other' },
    'installed CLI' => ->(data) { data['policy']['cli_sha256'] = 'other' },
    'destination mount' => ->(data) { data['mounted'] = false }
  }.each do |name, mutation|
    it "refuses interrupted-copy resume with changed #{name}" do
      worker('new', crash: 'sync')
      change_identity(&mutation)
      before = effects
      _out, _err, status = worker('resume')
      expect(status.exitstatus).to eq(7)
      expect(effects).to eq(before)
    end
  end

  it 'rejects a different immutable release without effects' do
    worker('new', crash: 'sync')
    before = effects
    expect do
      transaction.prepare('cycle', release: "sha256:#{'b' * 64}", root_generation: nil, resume: true)
    end.to raise_error(/Release mismatch/)
    expect(effects).to eq(before)
  end

  it 'observes an A/B boot switch without writes, accepting it, or replaying reboot' do
    worker('new')
    change_identity do |data|
      data['host']['boot_id'] = 'boot-two'
      data['host']['current'] = data['host']['target']
      data['host']['current_tree'] = data['target_tree']
      data['host']['target'] = 'fixture/ROOT/A'
    end
    File.unlink(File.join(store.path, '.lock'))
    out, err, status = worker('status')
    expect(status.success?).to be(true), err
    report = JSON.parse(out)
    expect(report['observation']).to include('boot_changed' => true, 'expected_target_booted' => true,
                                             'accepted' => false)
    expect(File.exist?(File.join(store.path, '.lock'))).to be(false)
    expect(effects).to eq(described_class::PHASES)
    _out, _err, status = worker('resume')
    expect(status.exitstatus).to eq(7)
    expect(effects).to eq(described_class::PHASES)
  end

  it 'refuses to create a new transaction over unresolved destructive work' do
    worker('new', crash: 'backup')
    expect do
      transaction.prepare('new-cycle', release: release, root_generation: '/fixture/release')
    end.to raise_error(/unresolved host transaction/)
    expect(effects).to eq(['backup'])
  end

  it 'does not create a lock or state while planning' do
    expect(transaction.plan(release: release, root_generation: '/fixture/release')).to include('read_only' => true)
    expect(Dir.children(store.path)).to be_empty
  end

  it 'rejects missing shared state before constructing a native updater or creating a lock' do
    allow(observation).to receive(:shared_state).and_raise('Missing dedicated ZFS filesystem')
    expect(transaction).not_to receive(:native_updater)
    expect do
      transaction.prepare('cycle', release: release, root_generation: '/fixture/release')
    end.to raise_error(/Missing dedicated/)
    expect(Dir.children(store.path)).to be_empty
  end

  it 'rejects a concurrent process with a real flock' do
    store.lock do
      _out, err, status = worker('new')
      expect(status.exitstatus).to eq(7)
      expect(err).to include('Another reset transaction is running')
      expect(Dir.children(store.path)).to eq(['.lock'])
    end
  end

  it 'never creates an absent state directory for status, plan or prepare' do
    Dir.rmdir(store.path)
    expect { transaction.status('cycle') }.to raise_error(Errno::ENOENT)
    expect { transaction.plan(release: release, root_generation: '/fixture/release') }.to raise_error(Errno::ENOENT)
    expect do
      transaction.prepare('cycle', release: release, root_generation: '/fixture/release')
    end.to raise_error(Errno::ENOENT)
    expect(File.exist?(store.path)).to be(false)
  end

  it 'rejects unsafe permissions, symlink and hardlink receipts, and path traversal IDs' do
    File.chmod(0o755, store.path)
    expect { store.validate! }.to raise_error(/private/)
    File.chmod(0o700, store.path)
    expect { store.read('../identity') }.to raise_error(/Invalid transaction ID/)
    File.symlink(File.join(@directory, 'identity'), File.join(store.path, 'cycle.json'))
    expect { store.read('cycle') }.to raise_error(Errno::ELOOP)
    File.unlink(File.join(store.path, 'cycle.json'))
    File.write(File.join(store.path, 'cycle.json'), '{}', perm: 0o600)
    File.link(File.join(store.path, 'cycle.json'), File.join(store.path, 'linked'))
    expect { store.read('cycle') }.to raise_error(/Unsafe transaction file/)
  end

  it 'leaves an intact old receipt if atomic rename fails' do
    worker('new', crash: 'sync')
    old = store.read('cycle')
    allow(File).to receive(:rename).and_raise(Errno::EIO)
    expect { store.write('cycle', old.merge('state' => 'stopped')) }.to raise_error(Errno::EIO)
    expect(store.read('cycle')).to eq(old)
    expect(Dir.children(store.path)).not_to include(a_string_starting_with('.receipt-'))
  end

  it 'retains an explicitly materialized supervisor report after worker state is removed' do
    out, err, status = worker('new')
    expect(status.success?).to be(true), err
    Dir.mktmpdir('nest-supervisor-artifacts-') do |artifacts|
      target = File.join(artifacts, 'cycle.json')
      File.open(target, 'w', 0o600) do |file|
        file.write(out)
        file.flush
        file.fsync
      end
      File.open(artifacts, File::RDONLY, &:fsync)
      readback = JSON.parse(File.read(target))
      expect(readback['phases'].size).to eq(described_class::PHASES.size)
      expect(readback).to include('schema' => 1, 'id' => 'cycle', 'state' => 'prepared')
      FileUtils.rm_rf(store.path)
      File.unlink(File.join(@directory, 'identity'))
      expect(JSON.parse(File.read(target))).to eq(readback)
      expect(File.read(target)).not_to include('SECRET')
      expect { File.read(File.join(artifacts, 'absent.json')) }.to raise_error(Errno::ENOENT)
    end
  end

  it 'refuses unknown reboot/finalize phase receipts instead of replaying them' do
    worker('new')
    data = store.read('cycle')
    data['phases'] << { 'phase' => 'reboot', 'state' => 'started' }
    store.write('cycle', data)
    expect { transaction.status('cycle') }.to raise_error(/Invalid phase/)
    before = effects
    _out, _err, status = worker('resume')
    expect(status.exitstatus).to eq(7)
    expect(effects).to eq(before)
  end

  it 'reports readback/fsync failure and does not run a phase after the failed intent write' do
    allow(store).to receive(:write).and_raise(Errno::EIO)
    updater = double('updater')
    expect(updater).not_to receive(:update)
    expect do
      transaction.prepare('cycle', release: release, root_generation: '/fixture/release', updater: updater)
    end.to raise_error(Errno::EIO)
    expect(File.exist?(File.join(@directory, 'effects'))).to be(false)
  end
end
