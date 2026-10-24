# frozen_string_literal: true

# Only fake effects on disposable ordinary files. Never calls native systemctl.
require 'nest/cli'
require_relative 'transaction_worker'

module RebootFixture
  class Store < Nest::UpdateStore
    def write(id, data)
      state = data.dig('reboot', 'state')
      raise 'Fixture write failure' if ENV['REBOOT_FAULT'] == "write-#{state}"

      super
      Process.kill('KILL', Process.pid) if ENV['REBOOT_FAULT'] == "saved-#{state}"
    end
  end

  class Transaction < Nest::UpdateTransaction
    def initialize(directory)
      @directory = directory
      super(store: Store.new(File.join(directory, 'state'), owner: Process.euid),
            observation: TransactionFixture::Observation.new(directory))
    end

    private

    def reboot_command
      raise 'Missing durable intent' unless @store.read('cycle').dig('reboot', 'state') == 'intent'
      raise 'Fixture launch failure SECRET' if ENV['REBOOT_FAULT'] == 'launch'

      File.open(File.join(@directory, 'reboots'), 'a') { |file| file.puts('submitted') }
      Process.kill('KILL', Process.pid) if ENV['REBOOT_FAULT'] == 'during-command'
      raise 'Fixture timeout SECRET' if ENV['REBOOT_FAULT'] == 'timeout'

      Process.kill('KILL', Process.pid) if ENV['REBOOT_FAULT'] == 'after-return'

      Integer(ENV.fetch('REBOOT_EXIT', '0'))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  directory = ARGV.shift
  transaction = RebootFixture::Transaction.new(directory)
  Nest::UpdateTransaction.define_singleton_method(:new) { transaction }
  Nest::CLI::Main.start(ARGV)
end
