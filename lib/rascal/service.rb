module Rascal
  class Service
    attr_reader :name, :container, :aliases, :env_variables, :command

    def initialize(name, env_variables: {}, image:, aliases:, volumes: [], command: nil, healthcheck_port: nil)
      @name = name
      @container = Docker::Container.new(name, image)
      @aliases = aliases
      @healthcheck_port = healthcheck_port
      @volumes = volumes
      @env_variables = env_variables
      @command = [*command]
    end

    # The TCP ports rascal waits for before running commands, of which one must accept
    # connections. Like the GitLab runner, takes HEALTHCHECK_TCP_PORT from the service's
    # own variables, or else the ports the image exposes.
    def ports
      if (port = @healthcheck_port.to_s[/\A\d+\z/])
        [port.to_i]
      else
        @container.exposed_tcp_ports
      end
    end

    def download_missing
      @container.download_missing
    end

    # Returns whether it started the service.
    def start_if_stopped(network: nil)
      if @container.running?
        false
      else
        @container.remove_if_network_missing(network)
        if (container_id = @container.id)
          network.disconnect(container_id)
        end
        @container.start(network: network, network_aliases: @aliases, volumes: @volumes, env: @env_variables, command: @command)
        true
      end
    end

    def running?
      @container.running?
    end

    def clean
      @container.clean
    end

    def update(**args)
      @container.update(**args)
    end
  end
end
