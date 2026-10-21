# frozen_string_literal: true

require 'nest/cli'
require 'nest/updater/rsync'
require 'tty-command'
require 'tmpdir'
require 'fileutils'

RSpec.describe 'transactional root copy on disposable directories' do
  it 'repairs partial equal-size/equal-mtime files and never copies boot/state or changes the source' do
    Dir.mktmpdir('nest-copy-') do |directory|
      source = File.join(directory, 'source')
      destination = File.join(directory, 'destination')
      [source, destination].each do |root|
        %w[boot var/lib/nest/updates var/db/pkg/category/package].each do |suffix|
          FileUtils.mkdir_p(File.join(root, suffix))
        end
      end
      File.write(File.join(source, 'var/db/pkg/category/package/CONTENTS'), '')
      File.write(File.join(source, 'data'), 'GOOD')
      File.write(File.join(source, 'boot/asset'), 'NEW BOOT')
      File.write(File.join(source, 'var/lib/nest/updates/receipt'), 'WRONG SOURCE STATE')
      File.write(File.join(destination, 'data'), 'BADD')
      File.utime(File.atime(File.join(source, 'data')), File.mtime(File.join(source, 'data')),
                 File.join(destination, 'data'))
      File.write(File.join(destination, 'boot/asset'), 'OLD BOOT')
      File.write(File.join(destination, 'var/lib/nest/updates/receipt'), 'DURABLE RECEIPT')
      rules = File.join(directory, 'filter.rules')
      File.write(rules, '')
      runner = TTY::Command.new(printer: :null, uuid: false)
      beadm = double('beadm', current: 'A', failure_exit_status: nil)
      allow(Nest::Beadm).to receive(:new).and_return(beadm)
      installer = double('installer', image: source)
      allow(Nest::Installer).to receive(:for_host).with(anything, image: source).and_return(installer)
      updater = Nest::Updater::Rsync.new(root_generation: source)
      allow(updater).to receive(:ensure_target_mounted).and_return(true)
      stub_const('Nest::CLI::ADMIN', '')
      command = double('command')
      allow(command).to receive(:run!) do |text, **options|
        expect(text).not_to include('root@falcon', '--inplace')
        expect(text).to include('--checksum')
        runner.run!(text.gsub('/etc/nest/reset-filter.rules', rules), **options)
      end
      allow(updater).to receive(:cmd).and_return(command)
      $DRY_RUN = false
      2.times do
        expect(updater.update(:sync, :sync, dir: destination, root_generation: source, format: 'json')).to be(true)
        expect(File.read(File.join(destination, 'data'))).to eq('GOOD')
        expect(File.read(File.join(destination, 'boot/asset'))).to eq('OLD BOOT')
        expect(File.read(File.join(destination, 'var/lib/nest/updates/receipt'))).to eq('DURABLE RECEIPT')
      end
      expect(File.read(File.join(source, 'data'))).to eq('GOOD')
      expect(updater.report[:commands]).to include(hash_including(operation: :root, native_exit: 0, success: true))
    end
  end
end
