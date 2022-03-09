# frozen_string_literal: true

module Nest
  class Runtime
    class Dir < Runtime
      include Nest::CLI

      attr_reader :dir

      def initialize(dir)
        super()
        @dir = dir
      end

      def exec(command = nil, options = {})
        logger.info "Running cmd '#{command}' with options '#{options}'"
      end
    end
  end
end
