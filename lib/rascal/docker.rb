module Rascal
  module Docker
    NAME_PREFIX = 'rascal-'

    autoload :Container, 'rascal/docker/container'
    autoload :Interface, 'rascal/docker/interface'
    autoload :Network,   'rascal/docker/network'
    autoload :Volume,    'rascal/docker/volume'

    class << self
      attr_writer :interface

      def interface
        @interface ||= Interface.new
      end
    end
  end
end
