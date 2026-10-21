# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'fileutils'

module Nest
  # Small private records: file fsync, atomic rename, directory fsync, readback.
  class UpdateStore
    attr_reader :path

    def initialize(path, owner: 0)
      @path = path
      @owner = owner
    end

    def validate!
      raise 'Run transactional reset as root' unless Process.euid == @owner
      raise 'State directory is missing or unsafe' unless File.realpath(path) == path

      stat = File.lstat(path)
      raise 'State directory must be private and owned by root' unless stat.directory? && stat.uid == @owner &&
                                                                       (stat.mode & 0o777) == 0o700

      parent = File.dirname(path)
      loop do
        stat = File.lstat(parent)
        raise 'Unsafe state ancestor' unless stat.directory? && [0, @owner].include?(stat.uid) &&
                                             stat.mode.nobits?(0o022)
        break if parent == '/'

        parent = File.dirname(parent)
      end
      true
    end

    def id!(id)
      raise 'Invalid transaction ID' unless id.is_a?(String) && id.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/)

      id
    end

    def lock
      validate!
      flags = File::RDWR | File::CREAT | File::NOFOLLOW | File::NONBLOCK
      File.open(File.join(path, '.lock'), flags, 0o600) do |file|
        private_file!(file)
        raise 'Another reset transaction is running' unless file.flock(File::LOCK_EX | File::LOCK_NB)

        begin
          yield
        ensure
          file.flock(File::LOCK_UN)
        end
      end
    end

    def private_file!(file)
      stat = file.stat
      raise 'Unsafe transaction file' unless stat.file? && stat.uid == @owner && stat.nlink == 1 &&
                                             (stat.mode & 0o777) == 0o600
    end

    def read(id)
      validate!
      File.open(filename(id), File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        private_file!(file)
        raise 'Transaction record is too large' if file.size > 1_048_576

        JSON.parse(file.read)
      end
    end

    def ids
      Dir.children(path).select { |name| name.end_with?('.json') }.map { |name| name.delete_suffix('.json') }
    end

    def write(id, record)
      target = filename(id)
      temporary = File.join(path, ".receipt-#{SecureRandom.hex(16)}")
      payload = JSON.generate(record)
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
          file.write(payload)
          file.flush
          file.fsync
        end
        File.rename(temporary, target)
        File.open(path, File::RDONLY, &:fsync)
        raise 'Receipt readback mismatch' unless read(id) == record
      ensure
        FileUtils.rm_f(temporary)
      end
    end

    private

    def filename(id)
      File.join(path, "#{id!(id)}.json")
    end
  end
end
