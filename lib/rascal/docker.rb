module Rascal
  module Docker
    NAME_PREFIX = 'rascal-'

    autoload :Container, 'rascal/docker/container'
    autoload :Interface, 'rascal/docker/interface'
    autoload :Network,   'rascal/docker/network'
    autoload :Volume,    'rascal/docker/volume'
  end
end
