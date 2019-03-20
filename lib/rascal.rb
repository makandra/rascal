require "rascal/version"

module Rascal
  class Error < StandardError; end

  autoload :Docker,                 'rascal/docker'
  autoload :Environment,            'rascal/environment'
  autoload :EnvironmentsDefinition, 'rascal/environments_definition'
  autoload :IOHelper,               'rascal/io_helper'
  autoload :Service,                'rascal/service'
end
