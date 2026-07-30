require 'shellwords'

module Rascal
  class Environment
    attr_reader :name, :network, :container, :env_variables, :services, :volumes, :working_dir, :before_shell

    def initialize(full_name, name:, image:, env_variables: {}, services: [], volumes: [], before_shell: [], after_shell: [], working_dir: nil)
      @name = name
      @network = Docker::Network.new(full_name)
      @container = Docker::Container.new(full_name, image)
      @env_variables = env_variables
      @services = services
      @volumes = volumes
      @working_dir = working_dir
      @before_shell = before_shell
      @after_shell = after_shell
    end

    def run_shell
      download_missing
      start_services
      command = [*@before_shell, 'bash', *@after_shell].join(';')
      @container.run_and_attach('bash', '-c', command,
        env: @env_variables,
        network: @network,
        volumes: @volumes,
        working_dir: @working_dir,
        allow_failure: true
      )
    end

    # Runs a single command in the environment, without a TTY, and returns its
    # Process::Status. Unlike #run_shell this is suitable for non-interactive
    # use (scripts, CI-like runs, AI agents), which need the command's real
    # exit status.
    #
    # The command is a list of arguments, which is escaped before being handed
    # to bash, so arguments may contain spaces and shell metacharacters. Use
    # e.g. `bash -c "foo && bar"` to run something the shell must interpret.
    def run_command(*command)
      download_missing
      start_services
      @container.run_and_attach('bash', '-c', command_script(Shellwords.join(command)),
        env: @env_variables,
        network: @network,
        volumes: @volumes,
        working_dir: @working_dir,
        allow_failure: true,
        tty: false
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

    # Runs before_shell/after_shell around the given command, but exits with the
    # command's status. Without saving it, an `after_shell` entry would determine
    # the exit status, and failures would go unnoticed.
    def command_script(command)
      [
        *@before_shell,
        command,
        '__rascal_status=$?',
        *@after_shell,
        'exit $__rascal_status',
      ].join(';')
    end

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
