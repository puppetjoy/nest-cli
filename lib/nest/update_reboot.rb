# frozen_string_literal: true

module Nest
  # Optional write-ahead reboot receipt; never replay a persisted intent.
  module UpdateReboot
    REBOOT_COMMAND = %w[systemctl --no-block reboot].freeze
    REBOOT_TIMEOUT = 10
    attr_reader :reboot_succeeded

    def reboot(id, plan: false)
      @reboot_succeeded = false
      return reboot_plan(id) if plan

      @store.id!(id)
      @store.validate!
      @observation.shared_state(@store.path)
      @store.lock do
        @record = load_record(id)
        raise 'Reboot already requested; inspect status, never resubmit' if record.key?('reboot')
        raise 'Reboot requires prepared state' unless record['state'] == 'prepared'

        reboot_identity!
        reboot_identity! # Reobserve immediately before the durable boundary.
        record['reboot'] = { 'schema' => 1, 'state' => 'intent', 'boot_id' => record.fetch('host').fetch('boot_id'),
                             'requested_at' => now, 'command' => REBOOT_COMMAND.dup }
        validate_reboot!(record)
        save
        intent = record
        @record = load_record(id) # Reopen and validate before command launch.
        raise 'Reboot intent readback mismatch' unless record == intent

        begin
          native_exit = reboot_command
          raise 'Unknown reboot command outcome' unless native_exit.is_a?(Integer) && native_exit.between?(0, 255)

          record['reboot'].merge!('state' => 'returned', 'finished_at' => now, 'native_exit' => native_exit)
          validate_reboot!(record)
          save
          completion = record
          @record = load_record(id)
          raise 'Reboot completion readback mismatch' unless record == completion

          @reboot_succeeded = native_exit.zero?
        rescue StandardError
          # Launch, timeout, signal or completion-write failure is not replay permission.
          # Only report what can actually be reopened; never invent a completion.
          @record = load_record(id)
        end
        report
      end
    end

    private

    def reboot_plan(id)
      @record = load_record(id)
      observed = bound_host!
      if observed.fetch('boot_id') == record.fetch('host').fetch('boot_id')
        raise 'Reboot requires prepared state' unless record['state'] == 'prepared'

        reboot_identity!
        reason = record.key?('reboot') ? 'already_requested' : 'eligible'
      else
        accepted_host! # A wrong changed boot is unsafe, not merely ineligible.
        reason = 'already_booted'
      end
      baseline = record
      result = status(id)
      raise 'Transaction changed during reboot plan' unless record == baseline

      result.merge('read_only' => true, 'reboot_eligible' => reason == 'eligible', 'reboot_reason' => reason)
    end

    def reboot_identity!
      unless record['capacity'] && record['capacity']['accounting_contract'].eql?(CapacityAdmission::ACCOUNTING_CONTRACT)
        raise 'Historical preparation lacks current capacity admission; export and inspect, never replay'
      end

      validate_capacity_policy!(nil)
      raise 'Reboot requires successful native preparation phases' unless reboot_phases_complete?(record)

      validate_identity!
      @observation.target_unmounted!(record.fetch('host').fetch('target'))
    end

    def reboot_requested
      return false unless record.key?('reboot')
      return nil if record['reboot']['state'] == 'intent'

      record['reboot']['native_exit'].zero?
    end

    def validate_reboot!(data)
      return unless data.key?('reboot')

      receipt = data['reboot']
      fields = %w[schema state boot_id requested_at command]
      fields += %w[finished_at native_exit] if receipt.is_a?(Hash) && receipt['state'] == 'returned'
      unless receipt.is_a?(Hash) && receipt.keys.sort == fields.sort && receipt['schema'].eql?(1) &&
             %w[intent returned].include?(receipt['state']) && receipt['command'] == REBOOT_COMMAND &&
             receipt['boot_id'].is_a?(String) && receipt['boot_id'] == data.fetch('host').fetch('boot_id') &&
             %w[prepared accepted finalizing finalized].include?(data['state']) &&
             reboot_phases_complete?(data) &&
             data['capacity'] && data['capacity']['accounting_contract'].eql?(CapacityAdmission::ACCOUNTING_CONTRACT)
        raise 'Invalid reboot receipt or preparation provenance'
      end

      requested = reboot_time!(receipt.fetch('requested_at'))
      unless data['phases'].all? { |row| Time.iso8601(row.fetch('finished_at')) <= requested }
        raise 'Reboot intent predates preparation'
      end
      return if receipt['state'] == 'intent'

      unless receipt['native_exit'].is_a?(Integer) && receipt['native_exit'].between?(0, 255) &&
             reboot_time!(receipt.fetch('finished_at')) >= requested
        raise 'Invalid reboot completion'
      end
    end

    def reboot_time!(value)
      unless value.is_a?(String) && value.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z\z/)
        raise 'Invalid reboot UTC timestamp'
      end

      parsed = Time.iso8601(value)
      raise 'Invalid reboot calendar timestamp' unless parsed.utc.strftime('%Y-%m-%dT%H:%M:%S') == value[0, 19]

      parsed
    end

    def reboot_phases_complete?(data)
      data.fetch('phases').size == UpdateTransaction::PHASES.size && data['phases'].all? do |row|
        row['state'] == 'complete' && [nil, 0].include?(row['native_exit']) &&
          row.fetch('commands').all? do |command|
            command['success'] == true && [nil, 0].include?(command['native_exit'])
          end
      end
    end

    # No shell, output capture, fallback or second launch. Bound child lifetime,
    # including a stuck systemctl; killing the client does not undo submission.
    def reboot_command
      pid = Process.spawn(*REBOOT_COMMAND, out: File::NULL, err: File::NULL)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + REBOOT_TIMEOUT
      loop do
        result = Process.waitpid2(pid, Process::WNOHANG)
        if result
          pid = nil # Never signal a reaped PID, which the OS may reuse.
          return result.last.exitstatus
        end

        raise 'Reboot command timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.05
      end
    ensure
      if pid
        begin
          Process.kill('KILL', pid)
          Process.waitpid(pid)
        rescue Errno::ESRCH, Errno::ECHILD
          # Already reaped, or died before cleanup.
        end
      end
    end
  end
end
