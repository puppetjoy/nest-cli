# frozen_string_literal: true

require 'nest/cli'
require 'nest/update_transaction'
require 'nest/reset_plan'
require 'json'

RSpec.describe 'transaction Thor interface' do
  let(:transaction) { instance_double(Nest::UpdateTransaction) }
  let(:report) { { 'schema' => 1, 'kind' => 'reset_transaction_report', 'success' => true } }

  before do
    allow(Nest::UpdateTransaction).to receive(:new).and_return(transaction)
  end

  it 'routes both read-only aliases without constructing a native updater' do
    %w[status report].each do |action|
      expect(transaction).to receive(action == 'status' ? :status : :export).with('cycle').and_return(report)
      expect do
        Nest::CLI::Main.start(['reset', action, 'cycle', '--format=json'])
      end.to output("#{JSON.generate(report)}\n").to_stdout
    end
  end

  it 'routes exact transaction identity and immutable inputs through the real parser' do
    release = "sha256:#{'a' * 64}"
    expect(transaction).to receive(:prepare).with('cycle', release: release, root_generation: '/generation',
                                                           capacity_policy: '/capacity.json',
                                                           resume: false).and_return(report)
    expect do
      Nest::CLI::Main.start(['reset', '--transaction=cycle', "--release=#{release}",
                             '--root-generation=/generation', '--capacity-policy=/capacity.json', '--format=json'])
    end.to output("#{JSON.generate(report)}\n").to_stdout
  end

  it 'loads resume identity from the receipt, never from legacy --resume' do
    expect(transaction).to receive(:prepare).with('cycle', release: nil, root_generation: nil,
                                                           capacity_policy: nil, resume: true).and_return(report)
    expect do
      Nest::CLI::Main.start(['reset', '--resume-transaction=cycle', '--format=json'])
    end.to output("#{JSON.generate(report)}\n").to_stdout
  end

  it 'routes release-aware planner policy without a lock or native updater' do
    planner = instance_double(Nest::ResetPlan)
    allow(Nest::ResetPlan).to receive(:new).and_return(planner)
    planner_report = { observation_success: true, capacity: {} }
    expect(planner).to receive(:call).with(:backup, :activate, anything).and_return(planner_report)
    capacity = { 'admission' => 'admitted', 'admitted' => true }
    inputs = { release: 'digest', root_generation: '/generation', capacity_policy: '/policy' }
    expect(transaction).to receive(:plan).with(**inputs).and_return('capacity' => capacity)
    output = StringIO.new
    original = $stdout
    begin
      $stdout = output
      args = %w[reset --plan --release=digest --root-generation=/generation --capacity-policy=/policy --format=json]
      Nest::CLI::Main.start(args)
    ensure
      $stdout = original
    end
    expect(JSON.parse(output.string)['capacity']).to eq(capacity)
  end

  %w[json human].each do |format|
    it "returns exit 3 for denied capacity in #{format} mode through actual parser" do
      inputs = { release: nil, root_generation: nil, capacity_policy: '/policy', resume: false }
      expect(transaction).to receive(:prepare).with('cycle', **inputs).and_raise('Denied capacity: fixture')
      $logger = double(error: nil)
      output = StringIO.new
      original = $stdout
      begin
        $stdout = output
        expect do
          Nest::CLI::Main.start(['reset', '--transaction=cycle', '--capacity-policy=/policy', "--format=#{format}"])
        end.to raise_error(SystemExit) { |error| expect(error.status).to eq(3) }
      ensure
        $stdout = original
      end
      expect(JSON.parse(output.string)['error']).to include('Denied capacity') if format == 'json'
    end
  end

  it 'routes acceptance evidence through the real Thor parser' do
    expect(Nest::AcceptanceEvidence).to receive(:read).with('/collector.json').and_return('fixture')
    expect(transaction).to receive(:accept).with('cycle', evidence: 'fixture', postboot_policy: nil).and_return(report)
    expect do
      Nest::CLI::Main.start(['reset', 'accept', 'cycle', '--evidence=/collector.json', '--format=json'])
    end.to output("#{JSON.generate(report)}\n").to_stdout
  end

  it 'routes finalize and its read-only plan through the real Thor parser' do
    [false, true].each do |plan|
      expect(transaction).to receive(:finalize).with('cycle', cleanup: 'owned',
                                                              plan: plan ? true : nil).and_return(report)
      args = ['reset', 'finalize', 'cycle', '--cleanup=owned', '--format=json']
      args << '--plan' if plan
      expect { Nest::CLI::Main.start(args) }.to output("#{JSON.generate(report)}\n").to_stdout
    end
  end

  it 'loads explicit postboot policy separately from acceptance evidence' do
    expect(Nest::AcceptanceEvidence).to receive(:read).with('/context.json').and_return('context')
    expect(Nest::AcceptanceEvidence).to receive(:read).with('/collector.json').and_return('report')
    expect(transaction).to receive(:accept).with('cycle', evidence: 'report',
                                                       postboot_policy: 'context').and_return(report)
    expect do
      args = %w[reset accept cycle --evidence=/collector.json --postboot-policy=/context.json --format=json]
      Nest::CLI::Main.start(args)
    end.to output("#{JSON.generate(report)}\n").to_stdout
  end

  [%w[status cycle], %w[report cycle], %w[reboot cycle --plan], %w[reboot cycle --execute],
   %w[finalize cycle --cleanup=owned], %w[--transaction=cycle], %w[--resume-transaction=cycle], []].each do |args|
    it "rejects postboot policy for #{args.join(' ')}" do
      expect(transaction).not_to receive(:prepare)
      expect(transaction).not_to receive(:reboot)
      expect(transaction).not_to receive(:finalize)
      expect do
        expect do
          Nest::CLI::Main.start(['reset', *args, '--postboot-policy=/context.json', '--format=json'])
        end.to raise_error(SystemExit) { |error| expect(error.status).to eq(3) }
      end.to output(/only supported for accept/).to_stdout
    end
  end

  %w[--resume --kernel --firmware --step=sync --begin=mount --noop --test --dry-run --plan].each do |flag|
    it "refuses transaction preparation combined with #{flag}" do
      expect(transaction).not_to receive(:prepare)
      output = StringIO.new
      original = $stdout
      begin
        $stdout = output
        expect do
          Nest::CLI::Main.start(['reset', '--transaction=cycle', '--format=json', flag])
        end.to raise_error(SystemExit) { |error| expect(error.status).not_to eq(0) }
      ensure
        $stdout = original
      end
      expect(JSON.parse(output.string)).to include('success' => false)
    end
  end
end
