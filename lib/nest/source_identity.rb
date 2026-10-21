# frozen_string_literal: true

require 'digest'
require_relative 'version'

module Nest
  # Content identity works in release archives and installed gems without Git.
  module SourceIdentity
    def self.to_h
      base = File.expand_path('..', __dir__)
      files = Dir[File.join(base, '**/*.rb')].sort.to_h do |path|
        [path.delete_prefix("#{base}/"), Digest::SHA256.file(path).hexdigest]
      end
      manifest = files.map { |path, hash| "#{path}\0#{hash}\n" }.join
      { version: Nest::VERSION, algorithm: 'sha256', source_sha256: Digest::SHA256.hexdigest(manifest), files: files }
    end
  end
end
