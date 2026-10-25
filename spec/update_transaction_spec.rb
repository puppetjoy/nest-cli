# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'pty'
require 'nest/update_transaction'
require 'nest/cli'
require 'nest/updater/rsync'
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
    expect(transaction.plan(release: release, root_generation: '/fixture/release')).to include(
      'read_only' => true, 'capacity_admission' => 'unknown'
    )
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

  it 'requires policy before native updater construction and persists nothing beyond the lock' do
    expect(transaction).not_to receive(:native_updater)
    expect do
      transaction.prepare('cycle', release: release, root_generation: '/fixture/release')
    end.to raise_error(/requires --capacity-policy/)
    expect(store.ids).to be_empty
    expect(File.exist?(File.join(@directory, 'effects'))).to be(false)
  end

  it 'routes the actual CLI to the real missing-policy gate without native effects' do
    real_transaction = transaction
    allow(described_class).to receive(:new).and_return(real_transaction)
    output = StringIO.new
    original = $stdout
    begin
      $stdout = output
      expect do
        args = ['reset', '--transaction=cycle', "--release=#{release}"]
        args += %w[--root-generation=/fixture/release --format=json]
        Nest::CLI::Main.start(args)
      end.to raise_error(SystemExit) { |error| expect(error.status).to eq(3) }
    ensure
      $stdout = original
    end
    expect(JSON.parse(output.string)['error']).to include('requires --capacity-policy')
    expect(store.ids).to be_empty
    expect(File.exist?(File.join(@directory, 'effects'))).to be(false)
  end

  it 'refuses malformed and oversized policies in actual preparation without effects' do
    path = TransactionFixture.capacity_policy(@directory)
    ['{', ' ' * 16_385, '{"schema":true}', '{"schema":1,"schema":1}'].each do |text|
      File.write(path, text)
      expect do
        transaction.prepare('cycle', release: release, root_generation: '/fixture/release', capacity_policy: path)
      end.to raise_error(StandardError)
      expect(store.ids).to be_empty
    end
    expect(File.exist?(File.join(@directory, 'effects'))).to be(false)
  end

  it 'binds policy durably before effects and refuses replacement on interrupted-copy resume' do
    worker('new', crash: 'sync')
    receipt = store.read('cycle')
    expect(receipt['capacity']['policy_sha256']).to eq(Nest::CapacityPolicy.digest(receipt['capacity']['policy']))
    path = TransactionFixture.capacity_policy(@directory)
    policy = JSON.parse(File.read(path)).merge('write_budget_bytes' => 9999)
    File.write(path, JSON.generate(policy))
    expect do
      transaction.prepare('cycle', release: nil, root_generation: nil, resume: true, capacity_policy: path)
    end.to raise_error(/cannot replace/)
    expect(effects).to eq(%w[backup mount sync])
    change_identity { |data| data['capacity_denied'] = true }
    _out, err, status = worker('resume')
    expect(status.exitstatus).to eq(7)
    expect(err).to include('accounting changed')
    expect(effects).to eq(%w[backup mount sync])
  end

  it 'rechecks accounting after durable backup intent and refuses effects when it changes' do
    allow(store).to receive(:write).and_wrap_original do |method, id, data|
      method.call(id, data)
      if data['phases'].last&.slice('phase', 'state') == { 'phase' => 'backup', 'state' => 'started' }
        change_identity { |identity| identity['capacity_denied'] = true }
      end
    end
    updater = double('never run')
    expect(updater).not_to receive(:update)
    expect do
      transaction.prepare('cycle', release: release, root_generation: '/fixture/release', updater: updater,
                                   capacity_policy: TransactionFixture.capacity_policy(@directory))
    end.to raise_error(/accounting changed/)
    expect(store.read('cycle')['phases'].last).to include('state' => 'started', 'phase' => 'backup')
    expect(File.exist?(File.join(@directory, 'effects'))).to be(false)
  end

  it 'rechecks accounting after durable activation intent before selecting bootfs' do
    allow(store).to receive(:write).and_wrap_original do |method, id, data|
      method.call(id, data)
      if data['phases'].last&.slice('phase', 'state') == { 'phase' => 'activate', 'state' => 'started' }
        change_identity { |identity| identity['capacity_denied'] = true }
      end
    end
    expect do
      transaction.prepare('cycle', release: release, root_generation: '/fixture/release',
                                   updater: TransactionFixture::Updater.new(@directory, store),
                                   capacity_policy: TransactionFixture.capacity_policy(@directory))
    end.to raise_error(/accounting changed/)
    expect(observation.host['next_boot']).to eq('fixture/ROOT/A')
    expect(effects).to eq(%w[backup mount sync kernel unmount])
  end

  it 'exports historical preparation but refuses capacity retrofit or mutation, never replaying phases' do
    worker('new', crash: 'sync')
    data = store.read('cycle')
    data.delete('capacity')
    store.write('cycle', data)
    expect(transaction.export('cycle')['state']).to eq('pending')
    expect do
      transaction.prepare('cycle', release: nil, root_generation: nil, resume: true,
                                   capacity_policy: TransactionFixture.capacity_policy(@directory))
    end.to raise_error(/Historical preparation lacks capacity.*never replay/)
    expect(effects).to eq(%w[backup mount sync])
  end

  it 'refuses corrupt persisted policy or observation digests before resume or export' do
    worker('new', crash: 'sync')
    original = store.read('cycle')
    %w[policy_sha256 observations_sha256].each do |key|
      data = JSON.parse(JSON.generate(original))
      if key == 'policy_sha256'
        data['capacity'][key] = 'bad'
      else
        data['capacity']['checks'][0][key] = 'bad'
      end
      store.write('cycle', data)
      expect { transaction.export('cycle') }.to raise_error(/digest/)
      expect do
        transaction.prepare('cycle', release: nil, root_generation: nil, resume: true)
      end.to raise_error(/digest/)
    end
    expect(effects).to eq(%w[backup mount sync])
  end

  it 'exports old r2 accounting unchanged but never reinterprets it on interrupted-copy resume' do
    worker('new', crash: 'sync')
    data = store.read('cycle')
    data['capacity'].delete('accounting_contract')
    data['capacity']['checks'].each do |check|
      check['observations'].delete('accounting_contract')
      check['observations_sha256'] = Digest::SHA256.hexdigest(JSON.generate(check['observations']))
    end
    store.write('cycle', data)
    before = File.binread(File.join(store.path, 'cycle.json'))
    expect(transaction.export('cycle')['capacity']).to eq(data['capacity'])
    expect(observation).not_to receive(:capacity)
    expect do
      transaction.prepare('cycle', release: nil, root_generation: nil, resume: true,
                                   capacity_policy: TransactionFixture.capacity_policy(@directory))
    end.to raise_error(/stale capacity accounting contract.*never replay/)
    expect(File.binread(File.join(store.path, 'cycle.json'))).to eq(before)
    expect(effects).to eq(%w[backup mount sync])
  end

  it 'binds the accounting contract in every check and refuses missing, mixed or future contracts' do
    worker('new', crash: 'sync')
    original = store.read('cycle')
    expect(original['capacity']['accounting_contract']).to eq(3)
    [nil, 1, 4, 3.0, true].each do |version|
      data = JSON.parse(JSON.generate(original))
      data['capacity']['accounting_contract'] = version
      store.write('cycle', data)
      expect { transaction.export('cycle') }.to raise_error(/accounting contract/)
    end
    data = JSON.parse(JSON.generate(original))
    check = data['capacity']['checks'].last
    check['observations'].delete('accounting_contract')
    check['observations_sha256'] = Digest::SHA256.hexdigest(JSON.generate(check['observations']))
    store.write('cycle', data)
    expect { transaction.export('cycle') }.to raise_error(/accounting contract mismatch/)
    expect(effects).to eq(%w[backup mount sync])
  end

  it 'does not replay completed preparation for new capacity evidence' do
    worker('new')
    expect(observation).not_to receive(:capacity)
    expect(transaction.prepare('cycle', release: nil, root_generation: nil, resume: true)['success']).to be(true)
    expect(effects).to eq(described_class::PHASES)
  end

  def retain_contract_two
    data = store.read('cycle')
    data['capacity']['accounting_contract'] = 2
    data['capacity']['checks'].each do |check|
      check['observations']['accounting_contract'] = 2
      check['observations'].delete('shared_ancestors')
      check['observations_sha256'] = Digest::SHA256.hexdigest(JSON.generate(check['observations']))
    end
    store.write('cycle', data)
    data
  end

  it 'exports/observes contract 2 unchanged but refuses interrupted-copy upgrade before effects' do
    worker('new', crash: 'sync')
    data = retain_contract_two
    before = File.binread(File.join(store.path, 'cycle.json'))
    expect(transaction.export('cycle')['capacity']).to eq(data['capacity'])
    expect(transaction.status('cycle')['capacity']).to eq(data['capacity'])
    expect(observation).not_to receive(:capacity)
    expect do
      transaction.prepare('cycle', release: nil, root_generation: nil, resume: true)
    end.to raise_error(/stale capacity accounting contract.*never replay/)
    expect(File.binread(File.join(store.path, 'cycle.json'))).to eq(before)
    expect(effects).to eq(%w[backup mount sync])
  end

  [false, true].each do |requested|
    it "preserves contract 2 historical reboot status/export (requested=#{requested}) without reboot eligibility" do
      worker('new')
      if requested
        _out, err, status = reboot_worker('reboot', 'cycle', '--execute')
        expect(status.success?).to be(true), err
      end
      data = retain_contract_two
      before = File.binread(File.join(store.path, 'cycle.json'))
      expect(transaction.export('cycle')['capacity']).to eq(data['capacity'])
      expect(transaction.status('cycle')['capacity']).to eq(data['capacity'])
      expect { transaction.reboot('cycle', plan: true) }.to raise_error(/Historical.*current capacity/)
      expect { transaction.reboot('cycle') }.to raise_error(/Historical.*current capacity|already requested/)
      expect(File.binread(File.join(store.path, 'cycle.json'))).to eq(before)
      expect(reboot_effects.size).to eq(requested ? 1 : 0)
      expect(effects).to eq(described_class::PHASES)
    end
  end

  %w[new fresh].each do |boundary|
    it "refuses an old contract returned by #{boundary} accounting before native mutation" do
      calls = 0
      allow(observation).to receive(:capacity).and_wrap_original do |method, *args, **options|
        check = method.call(*args, **options)
        calls += 1
        if boundary == 'new' || calls > 1
          check['observations']['accounting_contract'] = 2
          check['observations_sha256'] = Digest::SHA256.hexdigest(JSON.generate(check['observations']))
        end
        check
      end
      updater = double('inert updater')
      expect(updater).not_to receive(:update)
      expect do
        transaction.prepare('cycle', release: release, root_generation: '/fixture/release', updater: updater,
                                     capacity_policy: TransactionFixture.capacity_policy(@directory))
      end.to raise_error(/current capacity accounting|Fresh capacity accounting contract/)
      expect(File.exist?(File.join(@directory, 'effects'))).to be(false)
    end
  end

  %w[missing identity projection quota refquota available].each do |fault|
    it "refuses corrupt contract 3 stored shared ancestry (#{fault}) even with a recomputed observation digest" do
      worker('new', crash: 'sync')
      data = store.read('cycle')
      check = data['capacity']['checks'].last
      ancestors = check['observations']['shared_ancestors']
      case fault
      when 'missing' then ancestors.delete('fixture/ROOT')
      when 'identity'
        ancestors['fixture/ROOT']['guid'] = '999'
        check['observations']['datasets']['fixture/ROOT']['guid'] = '999'
      when 'projection' then ancestors['fixture/ROOT']['used'] += 1
      when 'available'
        ancestors['fixture/ROOT']['available'] = 1
        check['observations']['datasets']['fixture/ROOT']['available'] = 1
      else
        ancestors['fixture/ROOT'][fault] = 1
        check['observations']['datasets']['fixture/ROOT'][fault] = 1
      end
      check['observations_sha256'] = Digest::SHA256.hexdigest(JSON.generate(check['observations']))
      store.write('cycle', data)
      expect { transaction.export('cycle') }.to raise_error(/shared ancestor|Shared ancestor/)
      expect do
        transaction.prepare('cycle', release: nil, root_generation: nil, resume: true)
      end.to raise_error(/shared ancestor|Shared ancestor/)
      expect(effects).to eq(%w[backup mount sync])
    end
  end

  it 'reports readback/fsync failure and does not run a phase after the failed intent write' do
    allow(store).to receive(:write).and_raise(Errno::EIO)
    updater = double('updater')
    expect(updater).not_to receive(:update)
    expect do
      transaction.prepare('cycle', release: release, root_generation: '/fixture/release', updater: updater,
                                   capacity_policy: TransactionFixture.capacity_policy(@directory))
    end.to raise_error(Errno::EIO)
    expect(File.exist?(File.join(@directory, 'effects'))).to be(false)
  end

  def prepare_with_native_kernel(puppet_exit)
    inert = TransactionFixture::Updater.new(@directory, store)
    allow(Nest::Beadm).to receive(:new).and_return(double(current: 'A', failure_exit_status: nil))
    allow(Nest::Installer).to receive(:for_host).and_return(double(image: '/fixture/release'))
    native = Nest::Updater::Rsync.new(root_generation: '/fixture/release')
    native.steps.each_key do |phase|
      next if phase == :kernel

      native.steps[phase] = -> { inert.update(phase, phase) }
    end
    runner = double('inert native runner')
    allow(native).to receive(:cmd).and_return(runner)
    allow(native).to receive(:forcecmd).and_return(runner)
    allow(native).to receive(:logger).and_return(double.as_null_object)
    allow(runner).to receive(:run!).and_return(double(exit_status: 0))
    allow(native).to receive(:nspawn).with('/mnt/B', /puppet agent --test --tags kernel/, any_args)
                                     .and_return(puppet_exit)
    allow(Dir).to receive(:[]).and_call_original
    allow(Dir).to receive(:[]).with('/fixture/release/lib/modules/*').and_return(['/fixture/release/lib/modules/test'])
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with('/etc/default/kexec-load').and_return(false)
    transaction.prepare('cycle', release: release, root_generation: '/fixture/release', updater: native,
                                 capacity_policy: TransactionFixture.capacity_policy(@directory))
  end

  [0, 2].each do |native_exit|
    it "preserves real kernel Puppet #{native_exit} through reopening, read-only eligibility and at-most-once intent" do
      prepared = prepare_with_native_kernel(native_exit)
      expect(prepared).to include('state' => 'prepared', 'success' => true)
      kernel = prepared['phases'].find { |row| row['phase'] == 'kernel' }
      expect(kernel['native_exit']).to be_nil
      expect(kernel['commands']).to include('operation' => 'puppet', 'native_exit' => native_exit, 'success' => true)
      before = File.binread(File.join(store.path, 'cycle.json'))
      expect(transaction.export('cycle')['phases']).to eq(prepared['phases'])
      expect(transaction.reboot('cycle', plan: true)['reboot_eligible']).to be(true)
      expect(File.binread(File.join(store.path, 'cycle.json'))).to eq(before)
      allow(transaction).to receive(:reboot_command).once.and_return(0)
      expect(transaction.reboot('cycle')['reboot_requested']).to be(true)
      expect { transaction.reboot('cycle') }.to raise_error(/already requested/)
      expect { transaction.prepare('cycle', release: nil, root_generation: nil, resume: true) }
        .to raise_error(/forbids preparation replay/)
    end
  end

  [1, 4, 6, nil].each do |native_exit|
    it "exports real failed kernel Puppet #{native_exit.inspect} unchanged without eligibility or replay" do
      stopped = prepare_with_native_kernel(native_exit)
      expect(stopped).to include('state' => 'stopped', 'success' => false)
      expect(stopped['phases'].last).to include('state' => 'failed', 'native_exit' => native_exit)
      before = File.binread(File.join(store.path, 'cycle.json'))
      expect(transaction.export('cycle')['phases']).to eq(stopped['phases'])
      expect { transaction.reboot('cycle', plan: true) }.to raise_error(/prepared state/)
      expect { transaction.prepare('cycle', release: nil, root_generation: nil, resume: true) }
        .to raise_error(/failed kernel.*never replay/)
      expect(File.binread(File.join(store.path, 'cycle.json'))).to eq(before)
    end
  end

  [nil, 0].each do |aggregate|
    it "retains historical successful unknown command exits and aggregate #{aggregate.inspect}" do
      worker('new')
      data = store.read('cycle')
      data['phases'].each do |row|
        row['native_exit'] = aggregate
        row['commands'].each { |command| command['native_exit'] = nil }
      end
      store.write('cycle', data)
      expect(transaction.reboot('cycle', plan: true)['reboot_eligible']).to be(true)
      expect(store.read('cycle')).to eq(data)
    end
  end

  [2, 1, 4, 6, true, false, '0', 0.0].each do |exit_value|
    it "rejects contradictory completed aggregate #{exit_value.inspect} on load and reboot" do
      worker('new')
      data = store.read('cycle')
      data['phases'][3]['native_exit'] = exit_value
      store.write('cycle', data)
      expect { transaction.export('cycle') }.to raise_error(/Completed phase/)
      expect { transaction.reboot('cycle', plan: true) }.to raise_error(/Completed phase/)
      expect(store.read('cycle')).to eq(data)
    end
  end

  [1, 4, 6, true, false, '2', 2.0, '0', 0.0].each do |exit_value|
    it "rejects contradictory completed Puppet exit #{exit_value.inspect}" do
      worker('new')
      data = store.read('cycle')
      data['phases'][3]['commands'] = [{ 'operation' => 'puppet', 'success' => true, 'native_exit' => exit_value }]
      store.write('cycle', data)
      expect { transaction.export('cycle') }.to raise_error(/Completed phase/)
      expect { transaction.reboot('cycle', plan: true) }.to raise_error(/Completed phase/)
      expect(store.read('cycle')).to eq(data)
    end
  end

  Nest::UpdateTransaction::PHASES.each do |phase|
    it "allows exit 2 only for kernel Puppet, not other operations in #{phase}" do
      worker('new')
      original = store.read('cycle')
      %w[copy source modules kexec puppet].each do |operation|
        next if phase == 'kernel' && operation == 'puppet'

        data = JSON.parse(JSON.generate(original))
        data['phases'].find { |row| row['phase'] == phase }['commands'] = [
          { 'operation' => operation, 'success' => true, 'native_exit' => 2 }
        ]
        store.write('cycle', data)
        expect { transaction.export('cycle') }.to raise_error(/Completed phase/)
        expect { transaction.reboot('cycle', plan: true) }.to raise_error(/Completed phase/)
        expect(store.read('cycle')).to eq(data)
      end
    end
  end

  [false, nil, 1, 'true'].each do |success|
    it "rejects malformed completed command success #{success.inspect}" do
      worker('new')
      data = store.read('cycle')
      data['phases'][3]['commands'][0]['success'] = success
      store.write('cycle', data)
      expect { transaction.export('cycle') }.to raise_error(/Completed phase/)
    end
  end

  [nil, true, [], { 'success' => true, 'operation' => false, 'native_exit' => 0 }].each do |command|
    it "refuses malformed completed command #{command.inspect} without changing the record" do
      worker('new')
      data = store.read('cycle')
      data['phases'][3]['commands'] = [command]
      store.write('cycle', data)
      expect { transaction.export('cycle') }.to raise_error(/Completed phase/)
      expect { transaction.reboot('cycle', plan: true) }.to raise_error(/Completed phase/)
      expect(store.read('cycle')).to eq(data)
    end
  end

  it 'refuses reordered phase provenance even when each command independently succeeds' do
    worker('new')
    data = store.read('cycle')
    data['phases'][2], data['phases'][3] = data['phases'][3], data['phases'][2]
    store.write('cycle', data)
    expect { transaction.export('cycle') }.to raise_error(/Invalid phase receipts/)
    expect { transaction.reboot('cycle', plan: true) }.to raise_error(/Invalid phase receipts/)
    expect(store.read('cycle')).to eq(data)
  end

  def reboot_worker(*args, fault: nil, native_exit: '0')
    Open3.capture3({ 'REBOOT_FAULT' => fault, 'REBOOT_EXIT' => native_exit }, RbConfig.ruby,
                   '-I', File.expand_path('../lib', __dir__),
                   File.join(__dir__, 'fixtures/reboot_worker.rb'), @directory, 'reset', *args, '--format=json')
  end

  def reboot_effects
    path = File.join(@directory, 'reboots')
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  %w[0 23 launch].each do |outcome|
    it "preserves human result/exception semantics on a true TTY for #{outcome}" do
      worker('new')
      env = { 'REBOOT_EXIT' => outcome == '23' ? '23' : '0', 'REBOOT_FAULT' => outcome == 'launch' ? 'launch' : nil }
      output = +''
      status = nil
      PTY.spawn(env, RbConfig.ruby, '-I', File.expand_path('../lib', __dir__),
                File.join(__dir__, 'fixtures/reboot_worker.rb'), @directory,
                'reset', 'reboot', 'cycle', '--execute') do |reader, writer, pid|
        writer.close
        begin
          loop { output << reader.readpartial(4096) }
        rescue Errno::EIO, EOFError
          # Linux PTY end of stream.
        end
        status = Process.wait2(pid).last
      end
      expect(status.exitstatus).to eq(outcome == '0' ? 0 : 2)
      expect(JSON.parse(output)['reboot_requested']).to eq(outcome == 'launch' ? nil : outcome == '0')
      expect(output).not_to include('SECRET', 'machine_id')
    end
  end

  it 'plans byte-for-byte read-only without a lock and submits exactly once through the actual CLI' do
    worker('new')
    File.unlink(File.join(store.path, '.lock'))
    before = Dir.children(store.path).to_h { |name| [name, File.binread(File.join(store.path, name))] }
    out, err, status = reboot_worker('reboot', 'cycle', '--plan')
    expect(status.success?).to be(true), err
    expect(JSON.parse(out)).to include('read_only' => true, 'reboot_eligible' => true,
                                       'reboot_reason' => 'eligible', 'reboot_requested' => false)
    expect(Dir.children(store.path).to_h { |name| [name, File.binread(File.join(store.path, name))] }).to eq(before)
    expect(reboot_effects).to be_empty
    out, err, status = reboot_worker('reboot', 'cycle', '--execute')
    expect(status.success?).to be(true), err
    expect(JSON.parse(out)).to include('state' => 'prepared', 'success' => true, 'accepted' => false,
                                       'reboot_requested' => true)
    expect(store.read('cycle')['reboot']).to include('state' => 'returned', 'native_exit' => 0)
    expect(reboot_worker('reboot', 'cycle', '--execute').last.success?).to be(false)
    expect(JSON.parse(reboot_worker('reboot', 'cycle', '--plan').first)).to include(
      'reboot_eligible' => false, 'reboot_reason' => 'already_requested'
    )
    expect(reboot_effects).to eq(['submitted'])
    expect(worker('resume').last.success?).to be(false)
    expect(effects).to eq(described_class::PHASES)
  end

  %w[saved-intent during-command after-return write-returned launch timeout].each do |fault|
    it "retains ambiguity and never resubmits after #{fault}" do
      worker('new')
      out, _err, status = reboot_worker('reboot', 'cycle', '--execute', fault: fault)
      expect(status.success?).not_to be(true)
      expect(JSON.parse(out)['reboot_requested']).to be_nil unless status.signaled?
      expect(store.read('cycle').dig('reboot', 'state')).to eq('intent')
      before = reboot_effects
      expect(reboot_worker('reboot', 'cycle', '--execute').last.success?).to be(false)
      expect(reboot_effects).to eq(before)
      expect(transaction.status('cycle')['reboot_requested']).to be_nil
      expect(transaction.export('cycle')['reboot_requested']).to be_nil
    end
  end

  it 'retains a known nonzero without conflating it with no attempt or replay permission' do
    worker('new')
    out, _err, status = reboot_worker('reboot', 'cycle', '--execute', native_exit: '23')
    expect(status.exitstatus).to eq(2)
    expect(JSON.parse(out)).to include('success' => true, 'reboot_requested' => false)
    expect(JSON.parse(out)['reboot']).to include('state' => 'returned', 'native_exit' => 23)
    expect(reboot_worker('reboot', 'cycle', '--execute').last.success?).to be(false)
    expect(reboot_effects).to eq(['submitted'])
  end

  it 'does not launch after intent write failure' do
    worker('new')
    expect(reboot_worker('reboot', 'cycle', '--execute', fault: 'write-intent').last.success?).to be(false)
    expect(store.read('cycle')).not_to have_key('reboot')
    expect(reboot_effects).to be_empty
  end

  it 'serializes real separate-process contenders with the same nonblocking host lock' do
    worker('new')
    results = Array.new(8) { Thread.new { reboot_worker('reboot', 'cycle', '--execute') } }.map(&:value)
    expect(results.count { |result| result.last.success? }).to eq(1)
    expect(reboot_effects).to eq(['submitted'])
  end

  %w[--resume --kernel --firmware --step=sync --begin=mount --end=sync --begin=backup --end=activate
     --noop --test --dry-run --force --hard --unknown
     --transaction=other --resume-transaction=cycle --release=digest --root-generation=/fixture
     --capacity-policy=/fixture --evidence=/fixture --cleanup=owned --plan].each do |flag|
    it "rejects reboot execute combined with #{flag} before submission" do
      worker('new')
      expect(reboot_worker('reboot', 'cycle', '--execute', flag).last.success?).to be(false)
      expect(reboot_effects).to be_empty
      expect(store.read('cycle')).not_to have_key('reboot')
    end
  end

  it 'requires a valid ID and explicit selection and forbids execute on all other routes' do
    worker('new')
    [%w[reboot cycle], %w[reboot ../cycle --execute], %w[reboot absent --execute],
     %w[status cycle --execute], %w[report cycle --execute], %w[accept cycle --execute],
     %w[finalize cycle --execute], %w[--execute], %w[--transaction=other --execute]].each do |args|
      expect(reboot_worker(*args).last.success?).to be(false)
    end
    expect(reboot_effects).to be_empty
  end

  {
    'machine' => ->(data) { data['host']['machine_id'] = 'other' },
    'hostname' => ->(data) { data['host']['hostname'] = 'other' },
    'boot' => ->(data) { data['host']['boot_id'] = 'boot-two' },
    'pool' => ->(data) { data['host']['pool_guid'] = '999' },
    'current GUID' => ->(data) { data['host']['current_tree'][0]['guid'] = '999' },
    'target GUID' => ->(data) { data['target_tree'][0]['guid'] = '999' },
    'next boot' => ->(data) { data['host']['next_boot'] = 'fixture/ROOT/A' },
    'source' => ->(data) { data['source']['guid'] = '999' },
    'shared GUID' => ->(data) { data['shared_state']['guid'] = '999' },
    'filter' => ->(data) { data['policy']['filter_sha256'] = 'other' },
    'CLI' => ->(data) { data['policy']['cli_sha256'] = 'other' },
    'mounts' => ->(data) { data['mounted'] = true }
  }.each do |name, mutation|
    it "refuses reboot with changed #{name} before intent" do
      worker('new')
      change_identity(&mutation)
      expect(reboot_worker('reboot', 'cycle', '--execute').last.success?).to be(false)
      expect(reboot_worker('reboot', 'cycle', '--plan').last.success?).to be(false)
      expect(store.read('cycle')).not_to have_key('reboot')
      expect(reboot_effects).to be_empty
    end
  end

  it 'does not retrofit capacity or failed preparation' do
    worker('new')
    original = store.read('cycle')
    [->(data) { data.delete('capacity') },
     ->(data) { data['capacity'].delete('accounting_contract') },
     ->(data) { data['phases'].last['state'] = 'failed' },
     ->(data) { data['state'] = 'stopped' }, ->(data) { data['state'] = 'pending' }].each do |mutation|
      data = JSON.parse(JSON.generate(original))
      mutation.call(data)
      store.write('cycle', data)
      expect(reboot_worker('reboot', 'cycle', '--execute').last.success?).to be(false)
      expect(store.read('cycle')).to eq(data)
    end
    expect(reboot_effects).to be_empty
  end

  it 'validates exact optional fields and provenance on status and historical export' do
    worker('new')
    reboot_worker('reboot', 'cycle', '--execute')
    original = store.read('cycle')
    [->(data) { data['reboot']['schema'] = 1.0 }, ->(data) { data['reboot']['extra'] = 'SECRET' },
     ->(data) { data['reboot']['native_exit'] = '0' }, ->(data) { data['reboot']['native_exit'] = 256 },
     ->(data) { data['reboot']['boot_id'] = 'boot-two' }, ->(data) { data['reboot']['command'] = ['reboot'] },
     ->(data) { data['reboot']['state'] = 'complete' }, ->(data) { data['reboot']['requested_at'] = false },
     ->(data) { data['reboot']['requested_at'] = '2000-01-01T00:00:00Z' },
     ->(data) { data['reboot']['finished_at'] = '2000-01-01T00:00:00Z' },
     ->(data) { data['reboot']['finished_at'] = '2026-10-24T12:00:00+00:00' },
     ->(data) { data['phases'].last['native_exit'] = 1 }].each do |mutation|
      data = JSON.parse(JSON.generate(original))
      mutation.call(data)
      store.write('cycle', data)
      expect { transaction.status('cycle') }.to raise_error(StandardError)
      expect { transaction.export('cycle') }.to raise_error(StandardError)
    end
    expect(reboot_effects).to eq(['submitted'])
  end
end
