# frozen_string_literal: true

require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'nest/update_observation'
require_relative 'fixtures/transaction_worker'

RSpec.describe Nest::CapacityAdmission do
  around do |example|
    Dir.mktmpdir('nest-capacity-') do |directory|
      @directory = directory
      @source_path = File.join(directory, 'source')
      Dir.mkdir(@source_path)
      File.write(File.join(@source_path, 'root'), 'fixture')
      @policy = JSON.parse(File.read(TransactionFixture.capacity_policy(directory)))
      @policy['write_budget_bytes'] = 1_000_000
      @policy['promotion_budget_bytes'] = 1000
      @host = { 'machine_id' => 'f' * 32, 'hostname' => 'fixture', 'pool_guid' => '101',
                'current' => 'fixture/ROOT/A', 'target' => 'fixture/ROOT/B',
                'current_tree' => [{ 'dataset' => 'fixture/ROOT/A' }] }
      @source = { 'dataset' => 'fixture/source', 'guid' => '301', 'release' => TransactionFixture::RELEASE,
                  'path' => @source_path }
      @datasets = %w[fixture fixture/ROOT fixture/ROOT/A fixture/ROOT/B fixture/source].to_h do |name|
        properties = Nest::CapacityAdmission::NUMERIC.to_h { |key| [key, '0'] }
        properties.merge!('used' => '100', 'referenced' => '100', 'logicalreferenced' => '200',
                          'available' => '10000000', 'origin' => '-')
        [name, properties]
      end
      @physical = { 'size' => '20000000', 'allocated' => '10000000', 'free' => '10000000', 'freeing' => '9000000' }
      @snapshots = ''
      @responses = {}
      fixture = <<~RUBY
        require 'json'
        key = JSON.generate([File.basename($PROGRAM_NAME), *ARGV])
        File.open(ENV.fetch('NEST_CAPACITY_LOG'), 'a') { |f| f.puts(key) }
        data = JSON.parse(File.read(ENV.fetch('NEST_CAPACITY_DATA')))
        abort('Unexpected fixture native read') unless data.key?(key)
        value = data.fetch(key)
        exit 9 if value == 'FAIL'
        print value
      RUBY
      %w[zfs zpool].each do |name|
        path = File.join(directory, name)
        File.write(path, "#!#{RbConfig.ruby}\n#{fixture}")
        File.chmod(0o700, path)
      end
      previous = ENV.to_h.slice('PATH', 'NEST_CAPACITY_DATA', 'NEST_CAPACITY_LOG')
      begin
        ENV['PATH'] = "#{directory}:#{ENV.fetch('PATH')}"
        ENV['NEST_CAPACITY_DATA'] = File.join(directory, 'native.json')
        ENV['NEST_CAPACITY_LOG'] = File.join(directory, 'reads')
        example.run
      ensure
        %w[PATH NEST_CAPACITY_DATA NEST_CAPACITY_LOG].each { |key| ENV[key] = previous[key] }
      end
    end
  end

  def publish
    pool_key = ['zpool', 'get', '-Hp', '-o', 'property,value', 'size,allocated,free,freeing', 'fixture']
    @responses[JSON.generate(pool_key)] =
      @physical.map { |key, value| "#{key}\t#{value}\n" }.join
    @responses[JSON.generate(['zfs', 'list', '-Hp', '-r', '-t', 'filesystem,volume', '-o', 'name,type', 'fixture'])] =
      @datasets.keys.map { |name| "#{name}\tfilesystem\n" }.join
    @datasets.each do |name, properties|
      @responses[JSON.generate(['zfs', 'get', '-Hp', '-o', 'property,value',
                                Nest::CapacityAdmission::PROPERTIES.join(','), name])] =
        properties.map { |key, value| "#{key}\t#{value}\n" }.join
    end
    snapshot_key = ['zfs', 'list', '-Hp', '-r', '-t', 'snapshot', '-o', 'name,used,clones', 'fixture']
    @responses[JSON.generate(snapshot_key)] = @snapshots
    File.write(ENV.fetch('NEST_CAPACITY_DATA'), JSON.generate(@responses))
  end

  def admit(stage = 'backup')
    publish
    described_class.new(Nest::UpdateObservation.new).call(@policy, @host, @source, stage: stage)
  end

  it 'admits a supported unconstrained layout using real native subprocess fixtures and ordinary-directory du' do
    result = admit
    expect(result).to include('admitted' => true, 'admission' => 'admitted')
    expect(result['observations']['source_lower_bound_bytes']).to be >= 200
    expect(result['observations']['promotion_bound_bytes']).to eq(100)
    expect(result['observations']['required_physical_bytes']).to eq(1_001_200)
    expect(result['observations_sha256']).to eq(Digest::SHA256.hexdigest(JSON.generate(result['observations'])))
    commands = File.readlines(ENV.fetch('NEST_CAPACITY_LOG')).map { |line| JSON.parse(line) }
    expect(commands.map { |args| args.take(2) }.uniq).to contain_exactly(%w[zfs list], %w[zfs get], %w[zpool get])
  end

  %w[release hostname host_identity_sha256 pool_guid source_guid].each do |field|
    it "refuses a different policy #{field}" do
      @policy[field] = case field
                       when 'release' then "sha256:#{'b' * 64}"
                       when 'host_identity_sha256' then 'b' * 64
                       when 'pool_guid', 'source_guid' then '999'
                       else 'other'
                       end
      expect { admit }.to raise_error(/mismatch/)
    end
  end

  %w[quota refquota reservation refreservation].each do |property|
    %w[fixture fixture/ROOT fixture/ROOT/A fixture/ROOT/B].each do |dataset|
      it "refuses #{property} on #{dataset}, including inherited ancestor limits" do
        @datasets[dataset][property] = '100000000'
        expect { admit }.to raise_error(/finite quota.*ancestor/)
      end
    end
  end

  it 'does not use compression, sparse holes, future freeing or rollback deletion to fit' do
    File.open(File.join(@source_path, 'sparse'), 'w') { |file| file.truncate(2_000_000) }
    expect { admit }.to raise_error(/source lower bound/)
    File.unlink(File.join(@source_path, 'sparse'))
    @policy['physical_reserve_bytes'] = 10_000_000
    expect { admit }.to raise_error(/physical free/)
    @policy['physical_reserve_bytes'] = 100
    @policy['slop_reserve_bytes'] = 10_000_000
    expect { admit }.to raise_error(/physical free/)
  end

  it 'refuses tiny write/promotion budgets and insufficient logical available' do
    @policy['write_budget_bytes'] = 1
    expect { admit }.to raise_error(/source lower bound/)
    @policy['write_budget_bytes'] = 1_000_000
    @policy['promotion_budget_bytes'] = 1
    expect { admit }.to raise_error(/snapshot-accounting bound/)
    @policy['promotion_budget_bytes'] = 1000
    @datasets['fixture/ROOT']['available'] = '0'
    expect { admit }.to raise_error(/logical available/)
  end

  it 'checks the actual backup snapshot name and activation origin/clone dependency' do
    @snapshots = "fixture/ROOT/A@beadm-clone-A-to-B\t10\tfixture/ROOT/B\n"
    @datasets['fixture/ROOT/A']['usedbysnapshots'] = '10'
    expect { admit }.to raise_error(/Snapshot-name collision/)
    @datasets['fixture/ROOT/B']['origin'] = 'fixture/ROOT/A@beadm-clone-A-to-B'
    expect(admit('activation')['admitted']).to be(true)
    @snapshots += "fixture/ROOT/B@collision\t0\t-\n"
    expect { admit('activation') }.to raise_error(/target snapshots/)
    @snapshots = "fixture/ROOT/A@beadm-clone-A-to-B\t10\tfixture/foreign\n"
    expect { admit('activation') }.to raise_error(%r{origin/dependency})
  end

  it 'refuses incomplete, duplicate and failed native reads instead of inventing zero' do
    @datasets['fixture/ROOT'].delete('quota')
    expect { admit }.to raise_error(/Incomplete dataset/)
    @datasets['fixture/ROOT']['quota'] = '-'
    expect { admit }.to raise_error(/invalid native/)
    @datasets['fixture/ROOT']['quota'] = '0'
    @physical.delete('free')
    expect { admit }.to raise_error(/Incomplete physical/)
    publish
    key = @responses.keys.find { |entry| JSON.parse(entry).first == 'zpool' }
    @responses[key] = 'FAIL'
    File.write(ENV.fetch('NEST_CAPACITY_DATA'), JSON.generate(@responses))
    expect do
      described_class.new(Nest::UpdateObservation.new).call(@policy, @host, @source)
    end.to raise_error(Nest::CommandFailure) { |error| expect(error.exit_status).to eq(9) }
  end

  it 'does not cache accounting across checks or credit pending freeing' do
    expect(admit['admitted']).to be(true)
    @physical.merge!('free' => '1', 'allocated' => '19999999')
    expect { admit }.to raise_error(/physical free/)
  end

  it 'refuses duplicate property/snapshot inventories and unsupported volumes' do
    publish
    key = @responses.keys.find { |entry| JSON.parse(entry).values_at(0, 1) == %w[zpool get] }
    @responses[key] += "free\t10000000\n"
    File.write(ENV.fetch('NEST_CAPACITY_DATA'), JSON.generate(@responses))
    expect do
      described_class.new(Nest::UpdateObservation.new).call(@policy, @host, @source)
    end.to raise_error(/Duplicate/)
    @snapshots = "fixture/ROOT/A@other\t0\t-\n" * 2
    expect { admit }.to raise_error(/Duplicate snapshot/)
    @snapshots = ''
    publish
    key = @responses.keys.find { |entry| JSON.parse(entry).include?('name,type') }
    @responses[key] += "fixture/volume\tvolume\n"
    File.write(ENV.fetch('NEST_CAPACITY_DATA'), JSON.generate(@responses))
    expect do
      described_class.new(Nest::UpdateObservation.new).call(@policy, @host, @source)
    end.to raise_error(/unsupported volume/)
  end

  it 'refuses missing ancestor inventory and current-origin ambiguity' do
    @datasets.delete('fixture/ROOT')
    expect { admit }.to raise_error(/ancestor/)
    @datasets['fixture/ROOT'] = @datasets['fixture'].dup
    @datasets['fixture/ROOT/A']['origin'] = 'fixture/foreign@old'
    expect { admit }.to raise_error(/current origin/)
  end
end

RSpec.describe Nest::CapacityPolicy do
  around do |example|
    Dir.mktmpdir('nest-policy-') do |directory|
      @path = TransactionFixture.capacity_policy(directory)
      @policy = JSON.parse(File.read(@path))
      example.run
    end
  end

  it 'canonicalizes key order and hashes the exact canonical data' do
    expect(described_class.digest(@policy)).to eq(described_class.digest(@policy.to_a.reverse.to_h))
    expect(described_class.read(@path)).to eq(@policy)
  end

  it 'keeps the documented exact schema and fixture synchronized with runtime fields' do
    schema = JSON.parse(File.read(File.expand_path('../docs/reset-capacity-policy.schema.json', __dir__)))
    fixture = described_class.read(File.expand_path('../docs/reset-capacity-policy.fixture-only.json', __dir__))
    expect(schema['required'].sort).to eq(described_class::FIELDS.sort)
    expect(schema['properties'].keys.sort).to eq(described_class::FIELDS.sort)
    expect(schema['additionalProperties']).to be(false)
    expect(fixture['kind']).to eq('nest_reset_capacity_policy')
  end

  [true, false, 1.5, -1, '1', nil].each do |value|
    it "refuses non-integer/nonnegative budgets #{value.inspect}" do
      @policy['write_budget_bytes'] = value
      expect { described_class.validate(@policy) }.to raise_error(/schema/)
    end
  end

  it 'refuses boolean schema, zero writes, unknown keys, duplicates, oversized and nonregular inputs' do
    [@policy.merge('schema' => true), @policy.merge('write_budget_bytes' => 0),
     @policy.merge('command' => 'true'), @policy.merge('path' => '/'),
     @policy.merge('admitted' => true)].each do |value|
      expect { described_class.validate(value) }.to raise_error(/schema/)
    end
    File.write(@path, JSON.generate(@policy).sub('{', '{"schema":1,'))
    expect { described_class.read(@path) }.to raise_error(/[Dd]uplicate/)
    File.write(@path, ' ' * (described_class::LIMIT + 1))
    expect { described_class.read(@path) }.to raise_error(/bounded/)
    expect { described_class.read(File.dirname(@path)) }.to raise_error(/bounded/)
    File.unlink(@path)
    File.symlink('/nonexistent-fixture', @path)
    expect { described_class.read(@path) }.to raise_error(Errno::ELOOP)
  end
end
