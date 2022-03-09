# frozen_string_literal: true

require_relative '../beadm'
require_relative 'dir'

module Nest
  class Runtime
    class BootEnv < Dir
      attr_reader :name

      def initialize(name)
        super("/mnt/#{name}")
        @name = name
        @beadm = Nest::Beadm.new
      end

      def exec(command = nil, options = {})
        premounted = @beadm.mount(name) == :mounted
        super(command, options)
        @beadm.unmount(name) unless premounted
      end
    end
  end
end
