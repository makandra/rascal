module Rascal
  module Docker
    NAME_PREFIX = 'rascal-'

    autoload :CommandContainers, 'rascal/docker/command_containers'
    autoload :Container,         'rascal/docker/container'
    autoload :Image,             'rascal/docker/image'
    autoload :Interface,         'rascal/docker/interface'
    autoload :Network,           'rascal/docker/network'
    autoload :Volume,            'rascal/docker/volume'

    class << self
      attr_writer :interface

      def interface
        @interface ||= Interface.new
      end

      # Arguments for `docker container create` or `run` that set environment variables.
      def env_args(env)
        env.flat_map { |key, value| ['-e', "#{key}=#{value}"] }
      end
    end
  end
end
