# frozen_string_literal: true

# Disposable-filesystem fixture only. Never instantiates a native updater or ZFS writer.
require 'nest/update_transaction'

module TransactionFixture
  RELEASE = "sha256:#{'a' * 64}"

  class Observation
    attr_reader :directory

    def initialize(directory)
      @directory = directory
    end

    def values
      JSON.parse(File.read(File.join(directory, 'identity')))
    end

    def shared_state(_path)
      values.fetch('shared_state')
    end

    def host
      values.fetch('host')
    end

    def source(_path, release)
      raise 'Release mismatch' unless release == RELEASE

      values.fetch('source')
    end

    def policy
      values.fetch('policy')
    end

    def tree(_target)
      values.fetch('target_tree')
    end

    def target_unmounted!(_target)
      raise 'Target mounted unexpectedly' if values['mounted']
    end

    def copy_target!(_target, expected)
      raise 'Mounted destination identity mismatch' unless values['mounted'] && tree(nil) == expected
    end
  end

  class Updater
    attr_reader :report

    def initialize(directory, store)
      @directory = directory
      @store = store
    end

    def update(phase, _stop, **_options)
      # Verify the actual on-disk write-ahead receipt before simulating an effect.
      receipt = @store.read('cycle')
      raise 'Side effect without a durable intent' unless receipt.fetch('phases').last.slice('phase', 'state') ==
                                                          { 'phase' => phase.to_s, 'state' => 'started' }

      File.open(File.join(@directory, 'effects'), 'a') { |file| file.puts(phase) }
      path = File.join(@directory, 'identity')
      identity = JSON.parse(File.read(path))
      identity['mounted'] = true if phase == :mount
      identity['mounted'] = false if phase == :unmount
      identity['host']['next_boot'] = identity['host']['target'] if phase == :activate
      File.write(path, JSON.generate(identity))
      if ENV['NEST_FIXTURE_CRASH'] == phase.to_s
        # SIGKILL means no Ruby ensure/rescue can manufacture completion.
        Process.kill('KILL', Process.pid)
      end
      success = ENV['NEST_FIXTURE_FAIL'] != phase.to_s
      @report = { commands: [{ operation: :copy, native_exit: success ? 0 : 23, success: success }],
                  native_exit: success ? nil : 23,
                  error: 'SECRET MUST NOT BE SERIALIZED', output: 'SECRET MUST NOT BE SERIALIZED' }
      success
    end
  end

  class Store < Nest::UpdateStore
    def write(id, data)
      super
      last = data.fetch('phases').last
      return unless last && last['state'] == 'complete' && ENV['NEST_FIXTURE_CRASH_RECEIPT'] == last['phase']

      Process.kill('KILL', Process.pid)
    end
  end

  def self.run(directory, mode)
    store = Store.new(File.join(directory, 'state'), owner: Process.euid)
    transaction = Nest::UpdateTransaction.new(store: store, observation: Observation.new(directory))
    result = if mode == 'status'
               transaction.status('cycle')
             else
               transaction.prepare('cycle', release: RELEASE, root_generation: '/fixture/release',
                                            resume: mode == 'resume', updater: Updater.new(directory, store))
             end
    puts JSON.generate(result)
  rescue StandardError => e
    warn e.message
    exit 7
  end
end

TransactionFixture.run(*ARGV) if $PROGRAM_NAME == __FILE__
