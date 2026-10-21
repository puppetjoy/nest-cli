# frozen_string_literal: true

require 'json'
data = JSON.parse(File.read(ENV.fetch('NEST_TRANSACTION_READ_FIXTURE')))
name = File.basename($PROGRAM_NAME)
File.open(ENV.fetch('NEST_TRANSACTION_READ_LOG'), 'a') { |file| file.puts(JSON.generate([name, *ARGV])) }
result = case [name, ARGV.first]
         when ['findmnt', '--json'] then JSON.generate('filesystems' => data.fetch('mounts'))
         when %w[zpool get] then data.fetch('pools').fetch(ARGV.last).fetch(ARGV[-2])
         when %w[zfs get] then data.fetch('properties').fetch(ARGV.last).fetch(ARGV[-2])
         when %w[zfs list] then data.fetch('trees').fetch(ARGV.last).map { |row| row.join("\t") }.join("\n")
         else
           raise "Unexpected command, including mutations: #{[name, *ARGV].inspect}"
         end
puts result
