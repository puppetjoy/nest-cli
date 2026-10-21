# frozen_string_literal: true

require 'nest/cli'
require 'nest/updater/rsync'
require 'tty-command'
require 'rbconfig'
require 'json'

RSpec.describe Nest::Updater::Rsync do
  let(:beadm) { double('beadm', current: 'A', list: %w[A B], failure_exit_status: nil) }
  let(:installer) { double('installer', image: '/fixture/host') }
  let(:runner) { double('command') }
  let(:commands) { [] }
  let(:statuses) { Hash.new(0) }
  let(:updater) { described_class.new }

  before do
    $DRY_RUN = false
    allow(Nest::Beadm).to receive(:new).and_return(beadm)
    allow(Nest::Installer).to receive(:for_host).and_return(installer)
    allow(updater).to receive(:cmd).and_return(runner)
    allow(updater).to receive(:forcecmd).and_return(runner)
    allow(updater).to receive(:logger).and_return(double.as_null_object)
    allow(Dir).to receive(:[]).and_call_original
    allow(Dir).to receive(:[])
      .with('/fixture/host/lib/modules/*')
      .and_return(['/fixture/host/lib/modules/6.18-fixture'])
    allow(File).to receive(:exist?).with('/etc/default/kexec-load').and_return(false)
    allow(runner).to receive(:run!) do |*args|
      command = args.first
      operation = if command == 'mountpoint'
                    :mountpoint
                  elsif command.include?('zsh -c')
                    :root
                  elsif command.include?('/usr/src/linux/')
                    :source
                  elsif command.include?('/lib/modules/')
                    :modules
                  else
                    raise "Unexpected command: #{args.inspect}"
                  end
      commands << operation
      TTY::Command::Result.new(statuses[operation], '', '')
    end
    allow(updater).to receive(:nspawn) do |_dir, command, **_options|
      raise "Unexpected nspawn: #{command}" unless command.include?('puppet agent --test --tags kernel')

      commands << :puppet
      statuses[:puppet]
    end
    allow(beadm).to receive(:mount).with('B').and_return(true)
    allow(beadm).to receive(:unmount).with('B').and_return(true)
    allow(beadm).to receive(:activate).with('B').and_return(true)
  end

  { root: :sync, source: :kernel, modules: :kernel, puppet: :kernel, mountpoint: :sync }.each do |operation, phase|
    it "stops on #{operation} failure and retains its native status" do
      statuses[operation] = 23
      expect(beadm).not_to receive(:activate)
      expect(updater.update(:sync, :activate)).to be(false)
      expect(updater.report)
        .to include(success: false, failed_phase: phase, failed_operation: operation, native_exit: 23)
      expect(commands.last).to eq(operation)
      expect(updater.report[:phases].last).to include(success: false)
    end
  end

  [0, 2].each do |status|
    it "accepts Puppet detailed exit #{status} without discarding it" do
      statuses[:puppet] = status
      expect(updater.update(:sync, :activate)).to be(true)
      expect(updater.report[:commands])
        .to include(hash_including(operation: :puppet, native_exit: status, success: true))
      expect(beadm).to have_received(:activate).with('B')
    end
  end

  it 'stops before clone creation when alternate removal fails' do
    allow(beadm).to receive(:destroy).with('B').and_return(false)
    expect(beadm).not_to receive(:create)
    expect(updater.update(:backup, :activate)).to be(false)
    expect(updater.report[:failed_phase]).to eq(:backup)
    expect(commands).to be_empty
  end

  it 'stops after failed unmount without attempting activation' do
    allow(beadm).to receive(:unmount).and_return(false)
    allow(beadm).to receive(:failure_exit_status).and_return(32)
    expect(beadm).not_to receive(:activate)
    expect(updater.update(:unmount, :activate)).to be(false)
    expect(updater.report).to include(failed_phase: :unmount, native_exit: 32)
  end

  it 'reports promotion failures at activation with the native exit' do
    allow(beadm).to receive(:activate).and_raise('Failed to promote boot environment clone')
    allow(beadm).to receive(:failure_exit_status).and_return(1)
    expect(updater.update(:activate, :activate)).to be(false)
    expect(updater.report).to include(failed_phase: :activate, native_exit: 1)
  end

  it 'does not treat an invalid or reversed range as a successful reset' do
    expect(updater.update(:missing, :activate)).to be(false)
    expect(updater.update(:activate, :sync)).to be(false)
    expect(commands).to be_empty
  end

  it 'does not guess which module ABI to remove if the source is ambiguous' do
    allow(Dir).to receive(:[]).with('/fixture/host/lib/modules/*').and_return([])
    expect(updater.update(:kernel, :kernel)).to be(false)
    expect(updater.report[:error]).to match(/exactly one/)
    expect(commands).not_to include(:modules, :puppet)
  end

  it 'reports missing firmware implementation instead of a successful log statement' do
    expect(updater.update(:firmware, :firmware, firmware: true)).to be(false)
    expect(updater.report[:failed_phase]).to eq(:firmware)
  end

  it 'sends root, source and module copy output to stderr in JSON mode' do
    expect(updater.update(:sync, :kernel, format: 'json')).to be(true)
    expect(runner).to have_received(:run!).with(anything, out: '/dev/stderr', err: '/dev/stderr').exactly(3).times
  end

  it 'checks kexec failure after successful Puppet, without unmounting or activating' do
    allow(File).to receive(:exist?).with('/etc/default/kexec-load').and_return(true)
    allow(runner).to receive(:run!)
      .with(/systemctl try-reload-or-restart/)
      .and_return(TTY::Command::Result.new(5, '', ''))
    expect(beadm).not_to receive(:unmount)
    expect(beadm).not_to receive(:activate)
    expect(updater.update(:kernel, :activate)).to be(false)
    expect(updater.report).to include(failed_operation: :kexec, native_exit: 5)
  end

  it 'emits one machine-readable reset failure with the native exit through the CLI' do
    statuses[:root] = 23
    allow(described_class).to receive(:new).and_return(updater)
    cli = Nest::CLI::Main.new([], format: 'json', begin: 'sync', end: 'activate')
    allow(cli).to receive(:cli_init)
    output = StringIO.new
    original = $stdout
    begin
      $stdout = output
      expect { cli.reset }.to raise_error(SystemExit) { |error| expect(error.status).to eq(Nest::CLI::USER_ERROR) }
    ensure
      $stdout = original
    end
    report = JSON.parse(output.string)
    expect(report).to include('success' => false, 'failed_phase' => 'sync', 'native_exit' => 23)
    expect(report['source_identity']['files']).to include('nest/beadm.rb')
  end

  it 'retains legacy resume as a skip-backup flag in the execution path' do
    allow(described_class).to receive(:new).and_return(updater)
    expect(beadm).not_to receive(:destroy)
    cli = Nest::CLI::Main.new([], format: 'human', resume: true, begin: 'backup', end: 'activate')
    allow(cli).to receive(:cli_init)
    expect { cli.reset }.to output(/only skips backup/).to_stderr
    expect(updater.report[:phases].first[:phase]).to eq(:mount)
  end
end

RSpec.describe 'tty-command native subprocess contract' do
  let(:runner) { TTY::Command.new(printer: :null, uuid: false) }

  it 'run raises ExitError on a real nonzero child and has no result accessor' do
    expect { runner.run(RbConfig.ruby, '-e', 'exit 23') }.to raise_error(TTY::Command::ExitError) do |error|
      expect(error.message).to include('exit status: 23')
      expect(error).not_to respond_to(:result)
    end
  end

  it 'run! returns a truthy failure result with the real native status' do
    result = runner.run!(RbConfig.ruby, '-e', 'exit 23')
    expect(result).to be_truthy
    expect(result.success?).to be(false)
    expect(result.exit_status).to eq(23)
  end

  [0, 2, 6].each do |status|
    it "returns native exit #{status} unchanged for the updater run path" do
      updater = Nest::Updater.allocate
      updater.instance_variable_set(:@dir, '/')
      updater.instance_variable_set(:@options, {})
      # Avoid sudo in this harmless subprocess-only regression.
      stub_const('Nest::CLI::ADMIN', '')
      expect(updater.send(:run, "#{RbConfig.ruby} -e 'exit #{status}'", runner: runner)).to eq(status)
    end
  end
end
