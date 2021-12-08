module Rascal
  class Service
    attr_reader :name, :container, :alias, :env_variables, :command

    def initialize(name, env_variables: {}, image:, alias_name:, volumes: [], command: nil)
      @name = name
      @container = Docker::Container.new(name, image)
      @alias = alias_name
      @volumes = volumes
      @env_variables = env_variables
      @command = [*command]
    end

    def download_missing
      @container.download_missing
    end

    def start_if_stopped(network: nil)
      unless @container.running?
        @container.start(network: network, network_alias: @alias, volumes: @volumes, env: @env_variables, command: @command)
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
