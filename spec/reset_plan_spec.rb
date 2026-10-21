# frozen_string_literal: true

require 'nest/cli'
require 'nest/reset_plan'
require 'nest/updater/rsync'
require 'json'

RSpec.describe Nest::ResetPlan do
  let(:reads) { [] }
  let(:plan) { described_class.new }
  let(:status) { double(success?: true, exitstatus: 0) }
  let(:root) { 'tank/crypt/ROOT' }
  let(:cli) { Nest::CLI::Main.new([], plan: true, format: 'json', begin: 'backup', end: 'activate') }

  before do
    # A closed read-only allowlist: any mutation or unexpected subprocess fails.
    allow(Open3).to receive(:capture2e) do |*args|
      reads << args
      output = case args
               when ['findmnt', '-rn', '-o', 'SOURCE', '--mountpoint', '/'],
                    ['zfs', 'list', '-H', '-o', 'name', "#{root}/A"]
                 "#{root}/A\n"
               when ['zpool', 'get', '-Hp', '-o', 'property,value', 'size,allocated,free,freeing', 'tank']
                 "size\t10000\nallocated\t8000\nfree\t2000\nfreeing\t0\n"
               when ['zfs', 'list', '-H', '-t', 'filesystem', '-o', 'name', '-r', root]
                 "#{root}\n#{root}/A\n#{root}/A/var\n#{root}/B\n#{root}/B/var\n"
               else
                 expected = ['zfs', 'get', '-Hp', '-o', 'property,value,source', described_class::PROPERTIES.join(',')]
                 raise "Forbidden subprocess: #{args.inspect}" unless args[0..5] == expected

                 described_class::PROPERTIES.map do |property|
                   value = { 'quota' => '9000', 'origin' => 'tank/crypt/ROOT/B@clone',
                             'canmount' => 'noauto' }.fetch(property, '100')
                   "#{property}\t#{value}\tinherited from tank/crypt\n"
                 end.join
               end
      [output, status]
    end
    expect(Nest::Updater::Rsync).not_to receive(:new)
    expect(Nest::Installer).not_to receive(:for_host)
    expect(Nest::Beadm).not_to receive(:new)
    allow(cli).to receive(:cli_init)
  end

  it 'separates physical free, reserves, ancestor quota and unknown snapshot transfer' do
    report = plan.call(:backup, :activate)
    expect(report).to include(read_only: true, observation_success: true, target: "#{root}/B", destination: '/mnt/B')
    capacity = report[:capacity]
    expect(capacity).to include(admission: 'unknown', admitted: nil)
    expect(capacity[:physical_pool]['free']).to eq(2000)
    expect(capacity[:reserve][:slop_bytes]).to be_nil
    expect(capacity[:promotion_accounting][:transferred_snapshot_bytes]).to be_nil
    ancestor = capacity[:datasets_and_ancestors].find { |row| row[:dataset] == 'tank/crypt' }
    expect(ancestor[:properties]['quota']).to eq(value: '9000', source: 'inherited from tank/crypt')
    expect(reads).not_to be_empty
  end

  it 'executes only allowlisted reads through the CLI, even with legacy destructive flags' do
    flags = { plan: true, format: 'json', begin: 'backup', end: 'activate',
              resume: false, noop: true, test: true, dry_run: false }
    cli = Nest::CLI::Main.new([], flags)
    allow(cli).to receive(:cli_init)
    expect { cli.reset }.to output(/"kind":"reset_plan"/).to_stdout
    expect(reads).not_to be_empty
  end

  it 'retains legacy skip-backup semantics and warns that resume is not transaction recovery' do
    cli = Nest::CLI::Main.new([], plan: true, format: 'json', begin: 'backup', end: 'activate', resume: true)
    allow(cli).to receive(:cli_init)
    expect { cli.reset }.to output(/"steps":\["mount","sync","kernel","unmount","activate"\]/).to_stdout
    expect(plan.call(:mount, :activate, resume: true)[:warnings]).to include(described_class::RESUME_WARNING)
  end

  it 'plans kernel-only operations against the current root without backup or activation' do
    report = plan.call(:kernel, :kernel, kernel: true)
    expect(report).to include(target: "#{root}/A", destination: '/', replaces_alternate: false)
    expect(report[:steps]).to eq([:kernel])
  end

  it 'fails observation on unreadable capacity and retains the native exit, not admission success' do
    allow(Open3).to receive(:capture2e)
      .with('zpool', 'get', '-Hp', '-o', 'property,value', 'size,allocated,free,freeing', 'tank')
      .and_return(['unavailable', double(success?: false, exitstatus: 7)])
    report = plan.call(:backup, :activate)
    expect(report).to include(observation_success: false, native_exit: 7)
    expect(report[:capacity]).to include(admission: 'unknown', admitted: nil)
  end

  it 'does not accept incomplete or unsupported pool properties as observed capacity' do
    allow(Open3).to receive(:capture2e)
      .with('zpool', 'get', '-Hp', '-o', 'property,value', 'size,allocated,free,freeing', 'tank')
      .and_return(["free\t2000\n", status])
    expect(plan.call(:backup, :activate))
      .to include(observation_success: false, error: 'Incomplete physical pool accounting')
  end

  it 'rejects stacked roots before collecting unrelated accounting' do
    allow(Open3).to receive(:capture2e)
      .with('findmnt', '-rn', '-o', 'SOURCE', '--mountpoint', '/')
      .and_return(["#{root}/A\n#{root}/B\n", status])
    expect(plan.call(:backup, :activate)[:observation_success]).to be(false)
    expect(reads).to be_empty
  end

  it 'rejects invalid step ranges before even the read-only discovery commands' do
    expect { described_class.steps(:activate, :sync) }.to raise_error(/Invalid/)
    expect(reads).to be_empty
  end

  it 'reports source identity independent of Git and the working directory' do
    identity = Nest::SourceIdentity.to_h
    expect(identity[:source_sha256]).to match(/\A[0-9a-f]{64}\z/)
    expect(identity[:files]).to include('nest/beadm.rb', 'nest/reset_plan.rb', 'nest/updater/rsync.rb')
    expect { Nest::CLI::Main.new.version }.to output("Nest CLI v#{Nest::VERSION}\n").to_stdout
    expect { Nest::CLI::Main.new([], format: 'json').version }.to output(/"source_sha256"/).to_stdout
    expect(reads).to be_empty
  end
end
