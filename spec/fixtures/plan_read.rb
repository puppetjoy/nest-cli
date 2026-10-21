# frozen_string_literal: true

# Executed only via fake binaries in the isolated CLI regression directory.
require 'json'
File.open(ENV.fetch('NEST_PLAN_READ_LOG'), 'a') do |file|
  file.puts(JSON.generate([File.basename($PROGRAM_NAME), ARGV]))
end
case [File.basename($PROGRAM_NAME), ARGV]
when ['findmnt', ['-rn', '-o', 'SOURCE', '--mountpoint', '/']],
     ['zfs', ['list', '-H', '-o', 'name', 'fixture/crypt/ROOT/A']]
  puts 'fixture/crypt/ROOT/A'
when ['zpool', ['get', '-Hp', '-o', 'property,value', 'size,allocated,free,freeing', 'fixture']]
  exit 9 if ENV['NEST_PLAN_FAIL']
  puts "size\t10000\nallocated\t8000\nfree\t2000\nfreeing\t0"
when ['zfs', ['list', '-H', '-t', 'filesystem', '-o', 'name', '-r', 'fixture/crypt/ROOT']]
  puts "fixture/crypt/ROOT\nfixture/crypt/ROOT/A\nfixture/crypt/ROOT/B"
else
  properties = %w[available used usedbysnapshots usedbydataset usedbychildren usedbyrefreservation
                  quota refquota reservation refreservation origin canmount guid]
  expected = ['get', '-Hp', '-o', 'property,value,source', properties.join(',')]
  datasets = %w[fixture fixture/crypt fixture/crypt/ROOT fixture/crypt/ROOT/A fixture/crypt/ROOT/B]
  unless File.basename($PROGRAM_NAME) == 'zfs' && ARGV[0..4] == expected && datasets.include?(ARGV[5]) && ARGV.size == 6
    warn "Forbidden fixture command: #{ARGV.inspect}"
    exit 99
  end
  properties.each { |property| puts "#{property}\t100\tlocal" }
end
