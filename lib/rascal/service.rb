module Rascal
  class Service
    attr_reader :name, :container, :aliases, :env_variables, :command

    def initialize(name, env_variables: {}, image:, aliases:, volumes: [], command: nil)
      @name = name
      @container = Docker::Container.new(name, image)
      @aliases = aliases
      @volumes = volumes
      @env_variables = env_variables
      @command = [*command]
    end

    def download_missing
      @container.download_missing
    end

    def start_if_stopped(network: nil)
      unless @container.running?
        @container.remove_if_network_missing(network)
        if (container_id = @container.id)
          network.disconnect(container_id)
        end
        @container.start(network: network, network_aliases: @aliases, volumes: @volumes, env: @env_variables, command: @command)
      end
    end

    def clean
      @container.clean
    end

    def update(**args)
      @container.update(**args)
    end
  end
end
