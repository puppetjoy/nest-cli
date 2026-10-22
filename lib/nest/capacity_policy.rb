# frozen_string_literal: true

require 'json'
require 'digest'

module Nest
  # Data only: never accepts commands, paths or caller-provided admission verdicts.
  class CapacityPolicy
    LIMIT = 16_384
    BUDGETS = %w[write_budget_bytes promotion_budget_bytes physical_reserve_bytes slop_reserve_bytes].freeze
    FIELDS = (%w[schema kind release hostname host_identity_sha256 pool_guid source_guid] + BUDGETS).freeze

    # Reject duplicates on JSON versions that delegate key insertion to Hash.
    class UniqueObject < Hash
      def []=(key, value)
        raise 'Duplicate capacity policy key' if key?(key)

        super
      end
    end

    def self.read(path)
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        raise 'Capacity policy must be a bounded regular file' unless file.stat.file? && file.size <= LIMIT

        text = file.read(LIMIT + 1)
        raise 'Capacity policy is too large' if text.bytesize > LIMIT

        validate(JSON.parse(text, object_class: UniqueObject))
      end
    end

    def self.validate(data)
      valid = data.is_a?(Hash) && data.keys.sort == FIELDS.sort && data['schema'].is_a?(Integer) &&
              data['schema'] == 1 && data['kind'] == 'nest_reset_capacity_policy' &&
              data['release'].is_a?(String) && data['release'].match?(/\Asha256:[0-9a-f]{64}\z/) &&
              data['hostname'].is_a?(String) && !data['hostname'].empty? &&
              data['host_identity_sha256'].is_a?(String) && data['host_identity_sha256'].match?(/\A[0-9a-f]{64}\z/) &&
              %w[pool_guid source_guid].all? { |key| data[key].is_a?(String) && data[key].match?(/\A[1-9][0-9]*\z/) } &&
              BUDGETS.all? { |key| data[key].is_a?(Integer) && data[key] >= 0 } && data['write_budget_bytes'].positive?
      raise 'Invalid capacity policy schema' unless valid

      FIELDS.sort.to_h { |key| [key, data.fetch(key)] }
    end

    def self.digest(data)
      Digest::SHA256.hexdigest(JSON.generate(validate(data)))
    end
  end
end
