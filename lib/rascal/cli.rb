require 'thor'

module Rascal
  module CLI
    autoload :Base,         'rascal/cli/base'
    autoload :Clean,        'rascal/cli/clean'
    autoload :Environments, 'rascal/cli/environments'
    autoload :Main,         'rascal/cli/main'
    autoload :Run,          'rascal/cli/run'
    autoload :Shell,        'rascal/cli/shell'
    autoload :Update,       'rascal/cli/update'
  end
end
