module Rascal
  class Service
    attr_reader :name, :image, :container, :aliases, :env_variables, :command

    def initialize(name, env_variables: {}, image:, aliases:, volumes: [], command: nil, healthcheck_port: nil)
      @name = name
      @image = Docker::Image.new(image)
      @container = Docker::Container.new(name, @image)
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
        @image.exposed_tcp_ports
      end
    end

    def download_missing
      @image.download_missing(user: @name)
    end

    # Returns whether it started the service.
    def start_if_stopped(network:)
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

    # Whether the service is running, but started so recently that it may not be ready yet.
    def starting?(seconds)
      started_at = @container.started_at
      running? && started_at && started_at > Time.now - seconds
    end

    def clean
      @container.clean
    end

    # For `rascal status`.
    def status
      {
        'aliases' => @aliases,
        'image' => @image.name,
        'image_present' => @image.present?,
        'command' => @command,
        'variables' => @env_variables,
        # Unknown until the image is downloaded.
        'wait_ports' => (ports if @image.present? || @healthcheck_port),
        **@container.status,
        'logs' => "docker logs #{@container.prefixed_name}",
      }
    end

    def update(**args)
      @image.update(**args)
    end
  end
end
