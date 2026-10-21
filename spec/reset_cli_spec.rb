# frozen_string_literal: true

require 'tmpdir'
require 'open3'
require 'json'
require 'rbconfig'

RSpec.describe 'reset CLI subprocess against isolated read-only binaries' do
  around do |example|
    Dir.mktmpdir('nest-plan-') do |directory|
      @directory = directory
      fixture = File.read(File.join(__dir__, 'fixtures/plan_read.rb'))
      %w[findmnt zfs zpool].each do |name|
        path = File.join(directory, name)
        File.write(path, "#!#{RbConfig.ruby}\n#{fixture}")
        File.chmod(0o700, path)
      end
      example.run
    end
  end

  def execute_plan(extra = {})
    env = { 'PATH' => "#{@directory}:#{ENV.fetch('PATH')}",
            'NEST_PLAN_READ_LOG' => File.join(@directory, 'reads.jsonl') }.merge(extra)
    executable = File.expand_path('../bin/nest', __dir__)
    lib = File.expand_path('../lib', __dir__)
    args = [RbConfig.ruby, '-I', lib, executable, 'reset', '--plan', '--format=json']
    out, err, status = Open3.capture3(env, *args)
    [JSON.parse(out), err, status]
  end

  it 'exercises Thor options, real initializers and JSON stdout without a real pool or image' do
    report, err, status = execute_plan
    expect(status.exitstatus).to eq(0), err
    expect(report).to include('observation_success' => true, 'read_only' => true)
    expect(report['target']).to eq('fixture/crypt/ROOT/B')
    expect(report['capacity']).to include('admission' => 'unknown', 'admitted' => nil)
    expect(report['source_identity']['files']).to include('nest/beadm.rb')
    reads = File.readlines(File.join(@directory, 'reads.jsonl')).map { |line| JSON.parse(line) }
    expect(reads.size).to eq(9)
    expect(reads.map(&:first).uniq).to contain_exactly('findmnt', 'zfs', 'zpool')
    expect(err).to eq('')
  end

  it 'returns CLI failure separately from the actual failed read native exit' do
    report, err, status = execute_plan('NEST_PLAN_FAIL' => '1')
    expect(status.exitstatus).to eq(2), err
    expect(report).to include('observation_success' => false, 'native_exit' => 9)
    expect(report['capacity']).to include('admission' => 'unknown', 'admitted' => nil)
  end
end
