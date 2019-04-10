module Rascal
  class Environment
    attr_reader :name, :network, :container, :env_variables, :services, :volumes, :working_dir, :before_shell

    def initialize(name, image:, env_variables: {}, services: [], volumes: [], before_shell: [], working_dir: nil)
      @name = name
      @network = Docker::Network.new(name)
      @container = Docker::Container.new(name, image)
      @env_variables = env_variables
      @services = services
      @volumes = volumes
      @working_dir = working_dir
      @before_shell = before_shell
    end

    def run_shell
      download_missing
      start_services
      command = [*@before_shell, 'bash'].join(';')
      @container.run_and_attach('bash', '-c', command,
        env: @env_variables,
        network: @network,
        volumes: @volumes,
        working_dir: @working_dir,
        allow_failure: true
      )
    end

    def clean(clean_volumes: false)
      @services.each(&:clean)
      @network.clean
      @volumes.each(&:clean) if clean_volumes
    end

    def update(skip: [])
      [
        *@services.collect { |s| s.update(skip: skip) },
        *@container.update(skip: skip),
      ]
    end

    private

    def download_missing
      @container.download_missing
      @services.each(&:download_missing)
    end

    def start_services
      @network.create unless @network.exists?
      @services.each { |s| s.start_if_stopped(network: @network) }
    end
  end
end
