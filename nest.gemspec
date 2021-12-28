# frozen_string_literal: true

require_relative 'lib/nest/version'

Gem::Specification.new do |spec|
  spec.name        = 'nest'
  spec.version     = Nest::VERSION
  spec.author      = 'James Lee'
  spec.email       = 'james@james.tl'
  spec.homepage    = 'https://james.tl/projects/nest/'
  spec.summary     = 'Commands for Nest administration'
  spec.description = <<-DESC
    This is a collection of command-line tools to install, upgrade, and
    generally administer my personal Linux distribution called Nest.
  DESC

  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.metadata['source_code_uri']       = 'https://gitlab.james.tl/nest/cli'

  spec.files         = Dir['lib/**/*.rb']
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 2.6.0'

  spec.add_dependency 'thor', '~> 1.1'
  spec.add_dependency 'tty-command', '~> 0.10.1'
  spec.add_dependency 'tty-logger', '~> 0.6.0'
end
