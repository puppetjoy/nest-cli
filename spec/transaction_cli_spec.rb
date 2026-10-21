# frozen_string_literal: true

require 'nest/cli'
require 'nest/update_transaction'
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
                                                           resume: false).and_return(report)
    expect do
      Nest::CLI::Main.start(['reset', '--transaction=cycle', "--release=#{release}",
                             '--root-generation=/generation', '--format=json'])
    end.to output("#{JSON.generate(report)}\n").to_stdout
  end

  it 'loads resume identity from the receipt, never from legacy --resume' do
    expect(transaction).to receive(:prepare).with('cycle', release: nil, root_generation: nil,
                                                           resume: true).and_return(report)
    expect do
      Nest::CLI::Main.start(['reset', '--resume-transaction=cycle', '--format=json'])
    end.to output("#{JSON.generate(report)}\n").to_stdout
  end

  it 'routes acceptance evidence through the real Thor parser' do
    expect(Nest::AcceptanceEvidence).to receive(:read).with('/collector.json').and_return('fixture')
    expect(transaction).to receive(:accept).with('cycle', evidence: 'fixture').and_return(report)
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
