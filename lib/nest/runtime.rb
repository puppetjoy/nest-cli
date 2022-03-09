# frozen_string_literal: true

module Nest
  class Runtime
    private_class_method def self.bootenv?(name)
      require_relative 'beadm'
      Nest::Beadm.new.list.include? name
    rescue RuntimetimeError
      # empty
    end

    def self.find(name, type = nil)
      if type == :bootenv || (type.nil? && bootenv?(name))
        require_relative 'runtime/bootenv'
        Nest::Runtime::BootEnv.new(name)
      elsif type == :mnt || (type.nil? && Dir.exist?("/mnt/#{name}"))
        require_relative 'runtime/dir'
        Nest::Runtime::Dir.new("/mnt/#{name}")
      elsif type == :host || (type.nil? && Dir.exist?("/nest/hosts/#{name}"))
        require_relative 'runtime/dir'
        Nest::Runtime::Dir.new("/nest/hosts/#{name}")
      elsif type == :image || (type.nil? && name =~ %r{^(stage\d|tools/)})
        require_relative 'runtime/image'
        Nest::Runtime::Image.new(name)
      else
        raise "'#{name}' not found"
      end
    end

    def exec(command = nil, options = {}); end
  end
end
