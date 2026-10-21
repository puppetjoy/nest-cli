# frozen_string_literal: true

require 'nest/cli'
require 'nest/beadm'
require 'nest/updater'
require 'open3'

RSpec.describe Nest::Beadm do
  # Stateful command double: no real ZFS commands or pools are used.
  let(:root) { 'tank/crypt/ROOT' }
  let(:current_fs) { "#{root}/A" }
  let(:filesystems) do
    {
      root => ['off', '-'],
      current_fs => ['noauto', "#{root}/B@clone"],
      "#{current_fs}/var" => ['noauto', "#{root}/B/var@clone"],
      "#{root}/B" => ['on', '-'],
      "#{root}/B/var" => ['on', '-'],
      "#{root}/C" => ['on', '-'],
      "#{root}/C/var" => ['on', '-']
    }
  end
  let(:commands) { [] }
  let(:failures) { [] }
  let(:runner) { double('command') }
  let(:log) { double('logger').as_null_object }
  let(:beadm) { described_class.new }
  let(:bootfs) { "#{root}/B" }
  let(:quotas) { {} }
  let(:promotion_usage) { {} }

  def inventory
    "#{filesystems.map { |fs, props| ([fs] + props).join("\t") }.join("\n")}\n"
  end

  before do
    # Also supports running these regressions against the original algorithm.
    allow_any_instance_of(described_class).to receive(:`) do |_instance, command|
      case command
      when 'zfs list -H -o name `findmnt -n -o SOURCE /`'
        "#{current_fs}\n"
      when "zfs list -H -o name,canmount,origin -r #{root}"
        inventory
      else
        raise "Unexpected shell read: #{command}"
      end
    end
    allow(Open3).to receive(:capture2e) do |*args|
      output = case args
               when ['findmnt', '-rn', '-o', 'SOURCE', '--mountpoint', '/'],
                    ['zfs', 'list', '-H', '-o', 'name', current_fs]
                 "#{current_fs}\n"
               when ['zfs', 'list', '-H', '-t', 'filesystem', '-o', 'name,canmount,origin', '-r', root]
                 inventory
               when ['zfs', 'list', '-H', '-o', 'name', '-r', root]
                 "#{filesystems.keys.join("\n")}\n"
               when ['zpool', 'get', '-H', '-o', 'value', 'bootfs', 'tank']
                 bootfs
               when ['zfs', 'list', '-H', '-o', 'name,mountpoint', '-r', "#{root}/C"]
                 "#{root}/C\t/\n#{root}/C/var\t/var\n"
               when %w[zfs mount]
                 "#{root}/C /mnt/C\n#{root}/C/var /mnt/C/var\n"
               else
                 raise "Unexpected read: #{args.inspect}"
               end
      [output, double(success?: true)]
    end
    allow_any_instance_of(described_class).to receive(:logger).and_return(log)
    allow_any_instance_of(described_class).to receive(:cmd).and_return(runner)
    allow_any_instance_of(described_class).to receive(:`).with("zfs list -H -o name -r #{root}") do
      "#{filesystems.keys.join("\n")}\n"
    end
    allow_any_instance_of(described_class).to receive(:`).with('zpool get -H -o value bootfs tank') { bootfs }
    allow(runner).to receive(:run!) do |command|
      command = command.delete_prefix(Nest::CLI::ADMIN)
      commands << command
      success = failures.none? { |pattern| pattern.match?(command) }
      if command =~ /^zfs promote (\S+)$/ && quotas[Regexp.last_match(1)]
        filesystem = Regexp.last_match(1)
        success &&= promotion_usage.fetch(filesystem) <= quotas.fetch(filesystem)
      end
      if success && command =~ /^zfs set canmount=(\S+) (\S+)$/
        filesystems.fetch(Regexp.last_match(2))[0] = Regexp.last_match(1)
      elsif success && command =~ /^zfs promote (\S+)$/
        filesystems.fetch(Regexp.last_match(1))[1] = '-'
      end
      double(success?: success, failure?: !success, exit_status: success ? 0 : 1)
    end
  end

  def expect_inactive_safe
    filesystems.each do |fs, props|
      next if fs == root || fs == current_fs || fs.start_with?("#{current_fs}/")

      expect(%w[off noauto]).to include(props[0]), fs
    end
    expect(commands.grep(/destroy|unmount|umount|quota=/)).to be_empty
  end

  it 'disables all inactive roots and descendants before a quota-limited promotion fails' do
    # Payload fits, but transferred snapshots push accounting above the quota.
    quotas[current_fs] = 100
    payload_usage = 80
    promotion_usage[current_fs] = payload_usage + 40
    expect(payload_usage).to be < quotas.fetch(current_fs)
    expect { beadm.activate }.to raise_error(/promote/)
    expect_inactive_safe
    expect(quotas.fetch(current_fs)).to eq(100)
    expect(filesystems.keys).to include("#{root}/B", "#{root}/B/var")
    expect(filesystems.fetch(current_fs)[0]).to eq('on')
    expect(filesystems.fetch("#{current_fs}/var")[0]).to eq('on')
  end

  it 'keeps inactive trees safe when a descendant promotion fails' do
    failures << %r{^zfs promote #{current_fs}/var$}
    expect { beadm.activate }.to raise_error(/promote/)
    expect_inactive_safe
  end

  it 'attempts every inactive tree when one property write fails and reports incomplete safety' do
    failures << %r{^zfs set canmount=noauto #{root}/B$}
    expect { beadm.activate }.to raise_error(/disable.*B/)
    expect(filesystems.fetch("#{root}/B/var")[0]).to eq('noauto')
    expect(filesystems.fetch("#{root}/C/var")[0]).to eq('noauto')
    expect(commands.grep(/promote|canmount=on|bootfs=/)).to be_empty
  end

  it 'continues disabling other datasets if a command raises' do
    command = Nest::CLI::ADMIN + "zfs set canmount=noauto #{root}/B"
    allow(runner).to receive(:run!).with(command).and_raise(IOError, 'command failed')
    expect { beadm.activate }.to raise_error(/disable.*command failed/)
    expect(filesystems.fetch("#{root}/C/var")[0]).to eq('noauto')
    expect(commands.grep(/promote|canmount=on|bootfs=/)).to be_empty
  end

  it 'keeps inactive trees safe on failure enabling the current tree' do
    failures << /^zfs set canmount=on /
    expect { beadm.activate }.to raise_error(/enable/)
    expect_inactive_safe
    expect(commands.grep(/promote/)).to be_empty
  end

  it 'activates successfully without changing bootfs or destroying rollback data' do
    expect(beadm.activate).to be_truthy
    expect_inactive_safe
    expect(filesystems.fetch(current_fs)).to eq(['on', '-'])
    expect(filesystems.fetch("#{current_fs}/var")).to eq(['on', '-'])
    expect(commands.grep(/bootfs=/)).to be_empty
  end

  it 'preserves explicitly off datasets and does not confuse a similarly named inactive tree' do
    filesystems["#{current_fs}/disabled"] = ['off', '-']
    filesystems["#{root}/A.old"] = ['on', '-']
    expect(beadm.activate).to be_truthy
    expect(filesystems.fetch("#{current_fs}/disabled")[0]).to eq('off')
    expect_inactive_safe
  end

  it 'prepares already-selected targets rather than skipping their promotion' do
    filesystems.fetch("#{root}/B")[1] = "#{current_fs}@reset"
    filesystems.fetch("#{root}/B/var")[1] = "#{current_fs}/var@reset"
    expect(beadm.activate('B')).to be_truthy
    expect_inactive_safe
    expect(commands).to include("zfs promote #{root}/B", "zfs promote #{root}/B/var")
    expect(commands.grep(/bootfs=/)).to be_empty
  end

  it 'does not select a quota-limited reset clone for next boot' do
    filesystems.fetch("#{root}/C")[1] = "#{current_fs}@reset"
    quotas["#{root}/C"] = 100
    promotion_usage["#{root}/C"] = 120
    expect { beadm.activate('C') }.to raise_error(/promote/)
    expect_inactive_safe
    expect(commands.grep(/bootfs=/)).to be_empty
    expect(quotas.fetch("#{root}/C")).to eq(100)
  end

  it 'does not select a target if descendant promotion fails after root promotion' do
    filesystems.fetch("#{root}/C")[1] = "#{current_fs}@reset"
    filesystems.fetch("#{root}/C/var")[1] = "#{current_fs}/var@reset"
    failures << %r{^zfs promote #{root}/C/var$}
    expect { beadm.activate('C') }.to raise_error(/promote/)
    expect_inactive_safe
    expect(commands.grep(/bootfs=/)).to be_empty
  end

  it 'sets bootfs only after successful target root and descendant promotions' do
    filesystems.fetch("#{root}/C")[1] = "#{current_fs}@reset"
    filesystems.fetch("#{root}/C/var")[1] = "#{current_fs}/var@reset"
    expect(beadm.activate('C')).to be_truthy
    expect(commands.last).to eq("zpool set bootfs=#{root}/C tank")
    expect_inactive_safe
  end

  it 'reports failure setting bootfs without destroying rollback data' do
    failures << /^zpool set bootfs=/
    expect { beadm.activate('C') }.to raise_error(/bootfs/)
    expect_inactive_safe
  end

  it 'prepares rollback to the current environment through the ordinary command' do
    expect(beadm.activate('A')).to be_truthy
    expect(commands.last).to eq("zpool set bootfs=#{current_fs} tank")
    expect_inactive_safe
  end

  it 'propagates promotion failure through the update and reset activation caller' do
    instance = beadm
    allow(described_class).to receive(:new).and_return(instance)
    updater = Nest::Updater.new(activate: -> { updater.send(:activate) })
    filesystems.fetch("#{root}/B")[1] = "#{current_fs}@reset"
    failures << %r{^zfs promote #{root}/B$}
    expect { updater.update(:activate, :activate, boot_env: true) }.to raise_error(/promote/)
    expect_inactive_safe
    expect(commands.grep(/bootfs=/)).to be_empty
  end

  it 'rejects missing target names without any writes' do
    expect(beadm.activate('missing')).to be(false)
    expect(commands).to be_empty
  end

  it 'returns a nonzero CLI exit when activation safety is incomplete' do
    failures << /^zfs set canmount=noauto /
    cli = Nest::CLI::Beadm.new
    allow(cli).to receive(:beadm).and_return(beadm)
    allow(cli).to receive(:logger).and_return(log)
    expect { cli.activate }.to raise_error(SystemExit) do |error|
      expect(error.status).to eq(Nest::CLI::SYSTEM_ERROR)
    end
  end

  it 'rejects stacked roots without querying or modifying an unintended dataset' do
    allow(Open3).to receive(:capture2e)
      .with('findmnt', '-rn', '-o', 'SOURCE', '--mountpoint', '/')
      .and_return(["#{current_fs}\n#{root}/B\n", double(success?: true)])
    expect { beadm }.to raise_error(/exactly one.*root/)
    expect(commands).to be_empty
  end

  it 'rejects failed root discovery without falling back to another dataset' do
    allow(Open3).to receive(:capture2e)
      .with('findmnt', '-rn', '-o', 'SOURCE', '--mountpoint', '/')
      .and_return(['cannot read mounts', double(success?: false, exitstatus: 1)])
    expect { beadm }.to raise_error(/cannot read mounts/)
    expect(commands).to be_empty
  end

  it 'rejects failed filesystem enumeration without reporting successful activation' do
    allow(Open3).to receive(:capture2e)
      .with('zfs', 'list', '-H', '-t', 'filesystem', '-o', 'name,canmount,origin', '-r', root)
      .and_return(['cannot list datasets', double(success?: false, exitstatus: 1)])
    expect { beadm.activate }.to raise_error(/cannot list datasets/)
    expect(commands).to be_empty
  end

  it 'rejects an incomplete inventory before any mutation' do
    filesystems.delete(current_fs)
    expect { beadm.activate }.to raise_error(/incomplete/)
    expect(commands).to be_empty
  end

  it 'retains the native promotion failure after the inactive-safety sweep' do
    filesystems.fetch("#{root}/C")[1] = "#{current_fs}@same-name"
    failures << %r{^zfs promote #{root}/C$}
    expect { beadm.activate('C') }.to raise_error(/promote/)
    expect(beadm.failure_exit_status).to eq(1)
    expect_inactive_safe
    expect(commands.grep(/bootfs=/)).to be_empty
  end

  it 'checks the actual unmount result and does not remove the mount directory on failure' do
    failures << %r{^umount -R /mnt/C$}
    expect(beadm.unmount('C')).to be(false)
    expect(beadm.failure_exit_status).to eq(1)
    expect(commands).to eq(['umount -R /mnt/C'])
  end

  it 'does not destroy rollback data after an actual unmount failure' do
    failures << %r{^umount -R /mnt/C$}
    expect(beadm.destroy('C')).to be(false)
    expect(commands.grep(/destroy/)).to be_empty
  end

  it 'refuses next-boot deletion without any activation, unmount or destroy commands' do
    expect(beadm.destroy('B')).to be(false)
    expect(commands).to be_empty
  end

  it 'does not discover or retire external clone-origin snapshots by a guessed name' do
    expect(beadm.destroy('C')).to be(true)
    expect(commands.grep(/destroy/)).to eq(["zfs destroy -r #{root}/C"])
    expect(commands.grep(/bootfs=/)).to be_empty
  end

  it 'rejects failed mount inventory instead of calling the environment already unmounted' do
    allow(Open3).to receive(:capture2e)
      .with('zfs', 'mount')
      .and_return(['unavailable', double(success?: false, exitstatus: 8)])
    expect { beadm.unmount('C') }.to raise_error(/unavailable/)
    expect(beadm.failure_exit_status).to eq(8)
    expect(commands).to be_empty
  end

  it 'refuses to call a tree mounted outside /mnt unmounted' do
    allow(Open3).to receive(:capture2e)
      .with('zfs', 'mount')
      .and_return(["#{root}/C /\n", double(success?: true)])
    expect { beadm.unmount('C') }.to raise_error(/outside/)
    expect(commands).to be_empty
  end
end
