# frozen_string_literal: true

require 'nest/update_observation'

RSpec.describe Nest::UpdateObservation, 'owned cleanup' do
  let(:observer) { described_class.new }
  let(:dataset) { 'fixture/ROOT/temporary' }
  let(:expected) do
    [{ 'dataset' => dataset, 'guid' => '601', 'mountpoint' => '/' },
     { 'dataset' => "#{dataset}/var", 'guid' => '602', 'mountpoint' => '/var' }]
  end
  let(:inventory) { [{ 'dataset' => 'fixture', 'guid' => '1', 'mountpoint' => 'none' }] + expected }
  let(:mounts) { [] }
  let(:commands) { [] }
  let(:snapshots) { '' }

  before do
    allow(observer).to receive(:host).and_return('fixture')
    allow(observer).to receive(:tree).with('fixture') { inventory }
    allow(observer).to receive(:tree).with(dataset) { expected }
    allow(observer).to receive(:mounts) { mounts }
    allow(observer).to receive(:property).with(anything, 'mounted').and_return('no')
    allow(observer).to receive(:read) do |*args|
      commands << args
      case args
      when ['zfs', 'list', '-Hp', '-r', '-t', 'snapshot', '-o', 'name', dataset] then snapshots
      when ['zfs', 'destroy', '-r', dataset] then ''
      else raise "Unexpected command: #{args}"
      end
    end
  end

  it 'uses exact recursive filesystem deletion only, never dependent/origin deletion or bootfs changes' do
    observer.destroy_owned!(dataset, expected, host: 'fixture')
    expect(commands.last).to eq(['zfs', 'destroy', '-r', dataset])
    expect(commands.flatten).not_to include('-R', '-f', 'bootfs')
  end

  it 'detects renamed surviving GUIDs and distinguishes absence from failed inventory' do
    inventory[1]['dataset'] = 'fixture/ROOT/user-kept'
    expect { observer.cleanup_tree(dataset, expected) }.to raise_error(/GUID moved/)
    inventory.slice!(1, 2)
    expect(observer.cleanup_tree(dataset, expected)).to be_nil
    allow(observer).to receive(:tree).with('fixture').and_raise('inventory unavailable')
    expect { observer.cleanup_tree(dataset, expected) }.to raise_error(/unavailable/)
  end

  %w[held dependent ambiguous].each do |kind|
    context "with #{kind} candidate snapshots" do
      let(:snapshots) { "#{dataset}@#{kind}" }

      it 'conservatively retains the whole candidate without attempting any destroy' do
        expect { observer.destroy_owned!(dataset, expected, host: 'fixture') }.to raise_error(/held or dependent/)
        expect(commands.none? { |args| args.include?('destroy') }).to be(true)
      end
    end
  end

  it 'refuses a mounted descendant or unexpected bind beneath the candidate mount path' do
    mounts << { 'source' => "#{dataset}/var", 'target' => '/elsewhere' }
    expect { observer.destroy_owned!(dataset, expected, host: 'fixture') }.to raise_error(/mounted datasets/)
    mounts.replace([{ 'source' => '/boot', 'target' => '/mnt/temporary/boot' }])
    expect { observer.destroy_owned!(dataset, expected, host: 'fixture') }.to raise_error(/mounted datasets/)
    expect(commands).to be_empty
  end

  it 'rechecks descendant ZFS mounted properties as well as mount inventory' do
    allow(observer).to receive(:property).with("#{dataset}/var", 'mounted').and_return('yes')
    expect { observer.destroy_owned!(dataset, expected, host: 'fixture') }.to raise_error(/descendant is mounted/)
    expect(commands).to be_empty
  end

  it 'refuses changed current/next observation immediately before native deletion' do
    allow(observer).to receive(:host).and_return('changed')
    expect do
      observer.destroy_owned!(dataset, expected, host: 'fixture')
    end.to raise_error(/immediately before deletion/)
    expect(commands.none? { |args| args.include?('destroy') }).to be(true)
  end

  it 'refuses changed GUIDs immediately before the native command' do
    altered = Marshal.load(Marshal.dump(expected))
    altered[1]['guid'] = '999'
    allow(observer).to receive(:cleanup_tree).and_return(altered)
    expect { observer.destroy_owned!(dataset, expected, host: 'fixture') }.to raise_error(/identity changed/)
    expect(commands).to be_empty
  end
end
