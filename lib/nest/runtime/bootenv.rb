# frozen_string_literal: true

require_relative '../beadm'
require_relative 'dir'

module Nest
  class Runtime
    # Run commands in a ZFS boot environment
    class BootEnv < Dir
      attr_reader :name

      def initialize(name)
        super("/mnt/#{name}")
        @name = name
        @beadm = Nest::Beadm.new
      end

      def exec(command = nil, options = {})
        premounted = @beadm.mount(name) == :mounted
        exit_status = super(command, options.merge(overlay: false))
        @beadm.unmount(name) unless premounted
        exit_status
      end
    end
  end
end
