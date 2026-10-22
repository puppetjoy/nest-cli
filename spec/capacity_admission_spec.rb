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
                'current_tree' => [{ 'dataset' => 'fixture/ROOT/A', 'guid' => '203' }],
                'alternate_tree' => [{ 'dataset' => 'fixture/ROOT/B', 'guid' => '204' }] }
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
      @types = {}
      @guids = @datasets.keys.each_with_index.to_h { |name, index| [name, (201 + index).to_s] }
      @guids['fixture/source'] = '301'
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
    inventory_key = ['zfs', 'list', '-Hp', '-r', '-t', 'filesystem,volume', '-o', 'name,type,guid', 'fixture']
    @responses[JSON.generate(inventory_key)] =
      @datasets.keys.map { |name| "#{name}\t#{@types.fetch(name, 'filesystem')}\t#{@guids.fetch(name)}\n" }.join
    @datasets.each do |name, properties|
      required = @types[name] == 'volume' ? Nest::CapacityAdmission::VOLUME_PROPERTIES : Nest::CapacityAdmission::PROPERTIES
      @responses[JSON.generate(['zfs', 'get', '-Hp', '-o', 'property,value',
                                required.join(','), name])] =
        properties.map { |key, value| "#{key}\t#{value}\n" }.join
    end
    snapshot_key = ['zfs', 'list', '-Hp', '-r', '-t', 'snapshot', '-o', 'name,guid,used,clones,userrefs', 'fixture']
    @responses[JSON.generate(snapshot_key)] = @snapshots.lines.each_with_index.map do |line, index|
      name, used, clones = line.strip.split("\t")
      "#{name}\t#{1001 + index}\t#{used}\t#{clones}\t1\n"
    end.join
    File.write(ENV.fetch('NEST_CAPACITY_DATA'), JSON.generate(@responses))
  end

  def admit(stage = 'backup')
    publish
    described_class.new(Nest::UpdateObservation.new).call(@policy, @host, @source, stage: stage)
  end

  def add_filesystem(name, properties = {})
    @datasets[name] = @datasets.fetch('fixture').merge(properties)
    @guids[name] = (400 + @guids.size).to_s
  end

  def add_volume(name)
    @types[name] = 'volume'
    @guids[name] = (400 + @guids.size).to_s
    @datasets[name] = described_class::VOLUME_PROPERTIES.to_h { |key| [key, '0'] }
    @datasets[name].merge!('origin' => '-', 'volsize' => '4096000', 'volblocksize' => '8192',
                           'used' => '100', 'referenced' => '100', 'logicalreferenced' => '200')
  end

  # Sanitized topology, not captured real accounting or a real generation/policy.
  def ordinary_layout(kind)
    @datasets.delete_if { |name, _| name != 'fixture' }
    %w[crypt crypt/ROOT crypt/home crypt/home/joy crypt/generations crypt/generations/release].each do |suffix|
      add_filesystem("fixture/#{suffix}")
    end
    @host.merge!('current' => 'fixture/crypt/ROOT/B', 'target' => 'fixture/crypt/ROOT/A')
    %w[A B].each do |be|
      ['', '/debug', '/src', '/var'].each { |suffix| add_filesystem("fixture/crypt/ROOT/#{be}#{suffix}") }
    end
    %w[current alternate].zip(%w[B A]).each do |key, be|
      @host["#{key}_tree"] = @datasets.keys.grep(%r{/ROOT/#{be}(?:/|$)}).map do |name|
        { 'dataset' => name, 'guid' => @guids.fetch(name) }
      end
    end
    @source.merge!('dataset' => 'fixture/crypt/generations/release',
                   'guid' => @guids.fetch('fixture/crypt/generations/release'))
    @policy['source_guid'] = @source['guid']
    @host['current_tree'].each do |row|
      name = row.fetch('dataset')
      target = name.sub('/B', '/A')
      snapshot = "#{name}@beadm-clone-A-to-B"
      @datasets[name]['usedbysnapshots'] = '10'
      @datasets[target]['origin'] = snapshot
      @snapshots += "#{snapshot}\t10\t#{target}\n"
    end
    add_volume('fixture/crypt/swap')
    return unless kind == 'owl'

    add_volume('fixture/crypt/fscache')
    @datasets['fixture/crypt/fscache']['refreservation'] = '4096000'
    add_filesystem('fixture/crypt/kubernetes')
    3.times do |index|
      add_filesystem("fixture/crypt/kubernetes/pvc-#{index}", 'quota' => '1000', 'available' => '1')
    end
    add_filesystem('fixture/crypt/home-backup', 'origin' => 'fixture/crypt/home/joy@retained')
    @datasets['fixture/crypt/home/joy']['usedbysnapshots'] = '10'
    @snapshots += "fixture/crypt/home/joy@retained\t10\tfixture/crypt/home-backup\n"
  end

  %w[builder1 owl].each do |kind|
    it "admits the sanitized #{kind} topology, retaining exact B-to-A old origins and unrelated allocations" do
      ordinary_layout(kind)
      result = admit
      observations = result.fetch('observations')
      expect(observations['accounting_contract']).to eq(2)
      expect(observations['datasets']['fixture/crypt/swap']).to include('type' => 'volume', 'volsize' => 4_096_000)
      expect(observations['datasets']['fixture/crypt/swap']).not_to have_key('available')
      affected = %w[fixture fixture/crypt fixture/crypt/ROOT fixture/crypt/generations]
      unrelated = %w[fixture/crypt/home/joy fixture/crypt/swap fixture/crypt/kubernetes/pvc-0]
      expect(observations['affected_datasets']).to include(*affected)
      expect(observations['affected_datasets']).not_to include(*unrelated)
      expect(observations['promotion_bound_bytes']).to eq(400)
      expect(observations['snapshots'].all? { |row| row['userrefs'] == 1 }).to be(true)
      @physical.merge!('free' => '1001199', 'allocated' => '18998801')
      expect { admit }.to raise_error(/physical free/)
      @physical.merge!('free' => '1001200', 'allocated' => '18998800')
      expect(admit['admitted']).to be(true)
      @policy['promotion_budget_bytes'] = 399
      expect { admit }.to raise_error(/snapshot-accounting bound/)
    end

    it "checks activation against exact new B-to-A origins on the #{kind} topology" do
      ordinary_layout(kind)
      @datasets.each_value { |props| props['origin'] = props['origin'].sub('beadm-clone-A-to-B', 'beadm-clone-B-to-A') }
      @snapshots = @snapshots.gsub('beadm-clone-A-to-B', 'beadm-clone-B-to-A')
      expect(admit('activation')['admitted']).to be(true)
      @snapshots += "fixture/crypt/ROOT/A@retained\t0\t-\n"
      expect { admit('activation') }.to raise_error(/target snapshots/)
    end
  end

  %w[fixture/ROOT/A/volume fixture/ROOT/B/volume].each do |name|
    it "refuses affected volume #{name}" do
      add_volume(name)
      expect { admit }.to raise_error(/unsupported volume in affected closure/)
    end
  end

  it 'refuses a newly nested source filesystem or volume before using its incomplete lower bound' do
    add_filesystem('fixture/source/new')
    expect { admit }.to raise_error(/source inventory.*one immutable filesystem/)
    add_volume('fixture/source/new')
    expect { admit }.to raise_error(/source inventory.*one immutable filesystem/)
  end

  %w[fixture/crypt fixture/crypt/ROOT fixture/crypt/generations fixture/crypt/generations/release].each do |name|
    %w[quota refquota reservation refreservation].each do |property|
      it "refuses finite affected #{property} on #{name} despite unrelated-volume support" do
        ordinary_layout('owl')
        @datasets[name][property] = '1'
        expect { admit }.to raise_error(/finite quota.*affected ancestor/)
      end
    end
  end

  it 'still enforces source apparent/reference lower bounds and affected logical availability on ordinary layouts' do
    ordinary_layout('owl')
    @datasets[@source['dataset']]['logicalreferenced'] = '1000001'
    expect { admit }.to raise_error(/source lower bound/)
    @datasets[@source['dataset']]['logicalreferenced'] = '200'
    @datasets['fixture/crypt/ROOT']['available'] = '1000999'
    expect { admit }.to raise_error(/logical available/)
  end

  it 'refuses unknown volume accounting and never substitutes filesystem-only properties' do
    ordinary_layout('owl')
    @datasets['fixture/crypt/swap']['volsize'] = '-'
    expect { admit }.to raise_error(/invalid native/)
    @datasets['fixture/crypt/swap'].delete('volsize')
    expect { admit }.to raise_error(/Incomplete dataset/)
  end

  %w[current alternate source].each do |binding|
    it "refuses changed #{binding} GUIDs in complete typed inventory" do
      ordinary_layout('owl')
      name = binding == 'source' ? @source['dataset'] : @host["#{binding}_tree"].last.fetch('dataset')
      @guids[name] = '999'
      expect { admit }.to raise_error(/Changed affected dataset GUID/)
    end
  end

  it 'refuses shared old origins and unrelated clones touching the mutation closure' do
    ordinary_layout('owl')
    snapshot = 'fixture/crypt/ROOT/B@beadm-clone-A-to-B'
    add_filesystem('fixture/crypt/foreign', 'origin' => snapshot)
    @snapshots = @snapshots.sub("#{snapshot}\t10\tfixture/crypt/ROOT/A",
                                "#{snapshot}\t10\tfixture/crypt/ROOT/A,fixture/crypt/foreign")
    expect { admit }.to raise_error(/snapshot clone dependencies/)
  end

  it 'refuses cross-tree alternate origins even with matching snapshot names and reciprocal clone rows' do
    ordinary_layout('owl')
    @datasets['fixture/crypt/ROOT/A']['origin'] = 'fixture/crypt/home/joy@retained'
    @snapshots = @snapshots.sub("fixture/crypt/ROOT/B@beadm-clone-A-to-B\t10\tfixture/crypt/ROOT/A",
                                "fixture/crypt/ROOT/B@beadm-clone-A-to-B\t10\t-")
    @snapshots = @snapshots.sub("\tfixture/crypt/home-backup\n", "\tfixture/crypt/home-backup,fixture/crypt/ROOT/A\n")
    expect { admit }.to raise_error(/snapshot clone dependencies/)
  end

  it 'refuses unknown clone rows, missing origin snapshots and incomplete bound target trees' do
    ordinary_layout('builder1')
    @snapshots = @snapshots.sub("\tfixture/crypt/ROOT/A\n", "\tfixture/unknown\n")
    expect { admit }.to raise_error(/clone dependencies/)
    @snapshots = ''
    expect { admit }.to raise_error(%r{origin/dependency})
    @datasets.each_value { |props| props['origin'] = '-' }
    @host['alternate_tree'].pop
    expect { admit }.to raise_error(/bound alternate-tree/)
  end

  it 'refuses duplicate GUIDs, invalid stages, overlapping roots and unbounded receipts' do
    @guids['fixture/source'] = @guids['fixture/ROOT/A']
    expect { admit }.to raise_error(/Duplicate capacity GUID/)
    @guids['fixture/source'] = '301'
    expect { admit('invented') }.to raise_error(/stage/)
    @source['dataset'] = 'fixture/ROOT'
    expect { admit }.to raise_error(/overlapping/)
    @source['dataset'] = 'fixture/source'
    160.times { |index| add_filesystem("fixture/unrelated-#{index}") }
    expect { admit }.to raise_error(/bounded receipt/)
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
    @datasets['fixture/ROOT/B']['origin'] = 'fixture/ROOT/A@beadm-clone-A-to-B'
    expect { admit }.to raise_error(/Snapshot-name collision/)
    expect(admit('activation')['admitted']).to be(true)
    @snapshots += "fixture/ROOT/B@collision\t0\t-\n"
    expect { admit('activation') }.to raise_error(/target snapshots/)
    @snapshots = "fixture/ROOT/A@beadm-clone-A-to-B\t10\tfixture/foreign\n"
    expect { admit('activation') }.to raise_error(%r{origin/dependency|clone dependencies})
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
    key = @responses.keys.find { |entry| JSON.parse(entry).include?('name,type,guid') }
    @responses[key] += "fixture/volume\tvolume\n"
    File.write(ENV.fetch('NEST_CAPACITY_DATA'), JSON.generate(@responses))
    expect do
      described_class.new(Nest::UpdateObservation.new).call(@policy, @host, @source)
    end.to raise_error(/incomplete typed/)
  end

  it 'refuses missing ancestor inventory and current-origin ambiguity' do
    @datasets.delete('fixture/ROOT')
    expect { admit }.to raise_error(/ancestor/)
    @datasets['fixture/ROOT'] = @datasets['fixture'].dup
    @datasets['fixture/ROOT/A']['origin'] = 'fixture/foreign@old'
    expect { admit }.to raise_error(%r{origin/dependency})
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
