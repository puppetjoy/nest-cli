# frozen_string_literal: true

module Nest
  # Native status is data, not a truthy command result or a parsed exception string.
  class CommandFailure < RuntimeError
    attr_reader :operation, :exit_status

    def initialize(operation, exit_status)
      @operation = operation
      @exit_status = exit_status
      super("#{operation} failed (native exit: #{exit_status.nil? ? 'unknown' : exit_status})")
    end
  end
end
