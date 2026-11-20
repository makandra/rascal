require "rascal/version"

module Rascal
  class Error < StandardError; end

  autoload :CommandScript,          'rascal/command_script'
  autoload :Docker,                 'rascal/docker'
  autoload :Environment,            'rascal/environment'
  autoload :EnvironmentsDefinition, 'rascal/environments_definition'
  autoload :IOHelper,               'rascal/io_helper'
  autoload :Service,                'rascal/service'
end
