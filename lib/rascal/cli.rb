require 'thor'

module Rascal
  module CLI
    autoload :Base,   'rascal/cli/base'
    autoload :Clean,  'rascal/cli/clean'
    autoload :Main,   'rascal/cli/main'
    autoload :Shell,  'rascal/cli/shell'
    autoload :Update, 'rascal/cli/update'
  end
end
