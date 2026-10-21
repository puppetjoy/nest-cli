# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'json'
require 'rbconfig'
require 'nest/update_observation'

RSpec.describe Nest::UpdateObservation do
  let(:observer) { described_class.new }
  let(:release) { "sha256:#{'a' * 64}" }
  let(:target_tree) do
    [{ 'dataset' => 'fixture/ROOT/B', 'guid' => '12', 'mountpoint' => '/' },
     { 'dataset' => 'fixture/ROOT/B/var', 'guid' => '13', 'mountpoint' => '/var' }]
  end

  def mount(source, target, options = 'rw')
    { 'source' => source, 'target' => target, 'fstype' => 'zfs', 'options' => options }
  end

  around do |example|
    Dir.mktmpdir('nest-observe-') do |directory|
      @directory = directory
      @state = File.join(directory, 'state')
      @source = File.join(directory, 'generation')
      Dir.mkdir(@state)
      Dir.mkdir(@source)
      %w[var/db/pkg usr/src/linux lib/modules].each do |suffix|
        FileUtils.mkdir_p(File.join(@source, suffix))
      end
      @data = {
        'mounts' => [mount('fixture/ROOT/A', '/'), mount('fixture/updates', @state),
                     mount('fixture/releases/one', @source, 'ro'),
                     mount('fixture/ROOT/B', '/mnt/B'), mount('fixture/ROOT/B/var', '/mnt/B/var')],
        'properties' => {
          'fixture' => { 'org.nest:host-id' => 'f' * 32 },
          'fixture/updates' => { 'mountpoint' => @state, 'readonly' => 'off', 'guid' => '401' },
          'fixture/releases/one' => { 'readonly' => 'on', 'org.nest:release' => release,
                                      'guid' => '301', 'createtxg' => '18' }
        },
        'pools' => { 'fixture' => { 'guid' => '101', 'bootfs' => 'fixture/ROOT/A' } },
        'trees' => {
          'fixture/ROOT/A' => [['fixture/ROOT/A', '11', '/']],
          'fixture/ROOT' => [['fixture/ROOT', '10', 'none'], ['fixture/ROOT/A', '11', '/'],
                             ['fixture/ROOT/B', '12', '/'], ['fixture/ROOT/B/var', '13', '/var']],
          'fixture/ROOT/B' => target_tree.map { |row| row.values_at('dataset', 'guid', 'mountpoint') },
          'fixture/releases/one' => [['fixture/releases/one', '301', @source]]
        }
      }
      @data_path = File.join(directory, 'data.json')
      fixture = File.read(File.join(__dir__, 'fixtures/transaction_read.rb'))
      %w[zfs zpool findmnt].each do |name|
        path = File.join(directory, name)
        File.write(path, "#!#{RbConfig.ruby}\n#{fixture}")
        File.chmod(0o700, path)
      end
      old = ENV.to_h.slice('PATH', 'NEST_TRANSACTION_READ_FIXTURE', 'NEST_TRANSACTION_READ_LOG')
      begin
        ENV['PATH'] = "#{directory}:#{ENV.fetch('PATH')}"
        ENV['NEST_TRANSACTION_READ_FIXTURE'] = @data_path
        ENV['NEST_TRANSACTION_READ_LOG'] = File.join(directory, 'reads')
        example.run
      ensure
        %w[PATH NEST_TRANSACTION_READ_FIXTURE NEST_TRANSACTION_READ_LOG].each { |key| ENV[key] = old[key] }
      end
    end
  end

  before do
    allow(observer).to receive(:machine_id).and_return('f' * 32)
    allow(observer).to receive(:boot_id).and_return('boot-one')
  end

  def publish
    File.write(@data_path, JSON.generate(@data))
  end

  it 'reads host/pool/BE GUIDs and shared state using real read-only subprocesses' do
    publish
    expect(observer.host).to include('current' => 'fixture/ROOT/A', 'target' => 'fixture/ROOT/B', 'pool_guid' => '101')
    expect(observer.shared_state(@state)).to include('guid' => '401')
    expect(observer.source(@source, release)).to include('guid' => '301', 'creation_txg' => '18')
    reads = File.readlines(File.join(@directory, 'reads')).map { |line| JSON.parse(line) }
    expect(reads).not_to be_empty
    expect(reads.map { |row| row.take(2) }.uniq).to contain_exactly(
      %w[findmnt --json], %w[zfs get], %w[zfs list], %w[zpool get]
    )
  end

  it 'refuses a per-BE or network filesystem before provisioning anything' do
    @data['mounts'].find { |row| row['target'] == @state }['source'] = 'fixture/ROOT/A/var/updates'
    publish
    expect { observer.shared_state(@state) }.to raise_error(/outside all ROOT/)
    @data['mounts'].find { |row| row['target'] == @state }['fstype'] = 'nfs4'
    publish
    expect { observer.shared_state(@state) }.to raise_error(/exact mount/)
  end

  it 'refuses absent, read-only, non-dedicated and foreign-host state' do
    row = @data['mounts'].find { |entry| entry['target'] == @state }
    row['options'] = 'ro'
    publish
    expect { observer.shared_state(@state) }.to raise_error(/writable/)
    row['options'] = 'rw'
    @data['properties']['fixture/updates']['mountpoint'] = '/other'
    publish
    expect { observer.shared_state(@state) }.to raise_error(/dedicated/)
    @data['properties']['fixture/updates']['mountpoint'] = @state
    @data['properties']['fixture']['org.nest:host-id'] = 'other'
    publish
    expect { observer.shared_state(@state) }.to raise_error(/host-local/)
    @data['mounts'].delete(row)
    publish
    expect { observer.shared_state(@state) }.to raise_error(/exact mount/)
  end

  it 'refuses a mutable or different-release root generation' do
    @data['properties']['fixture/releases/one']['readonly'] = 'off'
    publish
    expect { observer.source(@source, release) }.to raise_error(/immutable/)
    @data['properties']['fixture/releases/one']['readonly'] = 'on'
    @data['properties']['fixture/releases/one']['org.nest:release'] = 'other'
    publish
    expect { observer.source(@source, release) }.to raise_error(/immutable/)
  end

  it 'rejects nested source filesystems, stacked roots, and symlink source aliases' do
    @data['mounts'] << mount('fixture/other', "#{@source}/var")
    publish
    expect { observer.source(@source, release) }.to raise_error(/submounts/)
    @data['mounts'] << mount('fixture/ROOT/B', '/')
    publish
    expect { observer.host }.to raise_error(/exact mount/)
    link = File.join(@directory, 'alias')
    File.symlink(@source, link)
    expect { observer.source(link, release) }.to raise_error(/canonical/)
  end

  it 'validates the entire mounted destination tree and refuses extra shared mounts' do
    publish
    allow(File).to receive(:realpath).and_call_original
    allow(File).to receive(:realpath).with('/mnt/B').and_return('/mnt/B')
    %w[usr/src/linux lib/modules].each do |suffix|
      allow(File).to receive(:realpath).with("/mnt/B/#{suffix}").and_return("/mnt/B/#{suffix}")
    end
    expect(observer.copy_target!('fixture/ROOT/B', target_tree)).to be(true)
    @data['mounts'] << mount('fixture/updates', '/mnt/B/var/lib/nest/updates')
    publish
    expect { observer.copy_target!('fixture/ROOT/B', target_tree) }.to raise_error(/Unexpected/)
  end

  it 'refuses wrong GUIDs, wrong destination datasets and stacked destination mounts' do
    allow(File).to receive(:realpath).and_call_original
    allow(File).to receive(:realpath).with('/mnt/B').and_return('/mnt/B')
    @data['trees']['fixture/ROOT/B'][0][1] = '99'
    publish
    expect { observer.copy_target!('fixture/ROOT/B', target_tree) }.to raise_error(/identity changed/)
    @data['trees']['fixture/ROOT/B'][0][1] = '12'
    @data['mounts'].find { |row| row['target'] == '/mnt/B/var' }['source'] = 'fixture/ROOT/A/var'
    publish
    expect { observer.copy_target!('fixture/ROOT/B', target_tree) }.to raise_error(/identity mismatch/)
    @data['mounts'] << mount('fixture/ROOT/B', '/mnt/B')
    publish
    expect { observer.copy_target!('fixture/ROOT/B', target_tree) }.to raise_error(/exact mount/)
  end
end
