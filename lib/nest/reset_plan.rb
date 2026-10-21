# frozen_string_literal: true

require 'open3'
require 'socket'
require_relative 'command_failure'
require_relative 'source_identity'

module Nest
  # Observation only. Never constructs an updater, installer or runtime.
  class ResetPlan
    STEPS = %i[backup mount sync kernel unmount activate firmware].freeze
    PROPERTIES = %w[available used usedbysnapshots usedbydataset usedbychildren usedbyrefreservation
                    quota refquota reservation refreservation origin canmount guid].freeze
    RESUME_WARNING = 'Legacy --resume only skips backup; it is not transaction recovery. ' \
                     'Inspect the alternate before reuse.'

    def self.steps(start, stop)
      first = STEPS.index(start)
      last = STEPS.index(stop)
      raise 'Invalid reset step range' unless first && last && first <= last

      STEPS[first..last]
    end

    def call(start, stop, options = {})
      @report = nil
      capacity = { admission: 'unknown', admitted: nil,
                   reason: 'Read-only accounting cannot prove clone promotion admission.' }
      @report = { schema: 1, kind: 'reset_plan', read_only: true, observation_success: false,
                  source_identity: SourceIdentity.to_h, steps: self.class.steps(start, stop),
                  warnings: [], capacity: capacity }
      @report[:warnings] << RESUME_WARNING if options[:resume]
      roots = read('findmnt', '-rn', '-o', 'SOURCE', '--mountpoint', '/').lines.map(&:chomp)
      raise 'Expected exactly one mounted root; inspect stacked mounts' unless roots.size == 1

      current = read('zfs', 'list', '-H', '-o', 'name', roots.first).strip
      match = %r{\A(([^/\s]+)(?:/[^/\s]+)*/ROOT)/([^/\s]+)\z}.match(current)
      raise '/ is not a ZFS boot environment' unless match

      be_root, pool, current_be = match.captures
      target = current_be == 'A' ? 'B' : 'A'
      inplace = options[:kernel] || options[:firmware]
      @report.merge!(current: current, target: inplace ? current : "#{be_root}/#{target}",
                     destination: inplace ? '/' : "/mnt/#{target}",
                     image: "/nest/hosts/#{Socket.gethostname}",
                     replaces_alternate: !inplace && @report[:steps].include?(:backup))
      @report[:capacity][:physical_pool] = pool_properties(pool)
      @report[:capacity][:reserve] = {
        slop_bytes: nil, policy_reserve_bytes: nil,
        reason: 'Pool free is not allocatable headroom; slop and policy reserve are not inferred.'
      }
      @report[:capacity][:datasets_and_ancestors] = dataset_properties(be_root, pool)
      @report[:capacity][:promotion_accounting] = {
        transferred_snapshot_bytes: nil, snapshot_name_collisions: 'unknown',
        reason: 'Origin snapshot accounting may transfer on promotion; payload size and free bytes are not admission.'
      }
      @report[:observation_success] = true
      @report
    rescue StandardError => e
      @report ||= { schema: 1, kind: 'reset_plan', read_only: true, observation_success: false }
      @report.merge!(error: e.message, native_exit: e.is_a?(CommandFailure) ? e.exit_status : nil)
    end

    private

    def read(*args)
      output, status = Open3.capture2e(*args)
      raise CommandFailure.new("plan #{args.first} #{args[1]}", status.exitstatus) unless status.success?

      output
    end

    def pool_properties(pool)
      rows = read('zpool', 'get', '-Hp', '-o', 'property,value', 'size,allocated,free,freeing', pool)
      props = rows.lines.each_with_object({}) do |line, values|
        property, value = line.strip.split("\t", 2)
        unless %w[size allocated free freeing].include?(property) && value =~ /\A\d+\z/
          raise 'Invalid physical pool accounting'
        end

        values[property] = Integer(value, 10)
      end
      raise 'Incomplete physical pool accounting' unless props.keys.sort == %w[allocated free freeing size]

      props
    end

    def dataset_properties(be_root, pool)
      descendants = read('zfs', 'list', '-H', '-t', 'filesystem', '-o', 'name', '-r', be_root).lines.map(&:strip)
      raise 'Incomplete BE inventory' unless descendants.include?(@report[:current])
      raise 'Invalid BE inventory' unless descendants.all? { |fs| fs == be_root || fs.start_with?("#{be_root}/") }

      ancestors = be_root.split('/').each_index.map { |index| be_root.split('/')[0..index].join('/') }
      raise 'Invalid pool ancestry' unless ancestors.first == pool

      (ancestors + descendants).uniq.map do |dataset|
        properties = read('zfs', 'get', '-Hp', '-o', 'property,value,source', PROPERTIES.join(','), dataset)
        values = properties.lines.each_with_object({}) do |line, props|
          property, value, source = line.strip.split("\t", 3)
          raise 'Invalid dataset accounting' unless PROPERTIES.include?(property) && value && source

          props[property] = { value: value, source: source }
        end
        raise 'Incomplete dataset accounting' unless values.keys.sort == PROPERTIES.sort

        { dataset: dataset, properties: values }
      end
    end
  end
end
