require 'shellwords'

module Rascal
  class Environment
    include IOHelper

    # Where the host's SSH agent socket appears in the container.
    SSH_AGENT_SOCKET = '/run/rascal/ssh-agent.sock'

    # Docker Desktop's path for the host's SSH agent. Sockets from macOS cannot be mounted directly.
    DOCKER_DESKTOP_SSH_AGENT_SOCKET = '/run/host-services/ssh-auth.sock'

    # How long to wait for services to accept connections before running the command anyway.
    SERVICE_TIMEOUT_SECONDS = 30

    # A bash function that waits until a host accepts TCP connections on a port.
    WAIT_FOR_FUNCTION = <<~BASH.gsub(/\n\s*/, ' ').strip
      __rascal_wait_for() {
        for ((__rascal_try = 0; __rascal_try < #{SERVICE_TIMEOUT_SECONDS * 10}; __rascal_try++)); do
          (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null && return;
          sleep 0.1;
        done;
        echo "rascal: Service $1 does not accept connections on port $2 after #{SERVICE_TIMEOUT_SECONDS} seconds, continuing anyway." >&2;
      }
    BASH

    attr_reader :name, :network, :container, :env_variables, :services, :volumes, :working_dir, :before_shell,
      :problems, :warnings

    # `problems` prevent the environment from starting, but not from being cleaned.
    # `warnings` are shown before starting it.
    # With `ssh_agent`, the host's SSH agent and known hosts are available in the container,
    # so it can fetch private dependencies over SSH.
    def initialize(full_name, name:, image:, env_variables: {}, services: [], volumes: [], before_shell: [], after_shell: [], working_dir: nil, problems: [], warnings: [], ssh_agent: true)
      @name = name
      @network = Docker::Network.new(full_name)
      @container = Docker::Container.new(full_name, image)
      @env_variables = env_variables
      @services = services
      @volumes = volumes
      @working_dir = working_dir
      @before_shell = before_shell
      @after_shell = after_shell
      @problems = problems
      @warnings = warnings
      @ssh_agent = ssh_agent
    end

    def run_shell
      start
      run_in_container(script('bash'), tty: true)
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
      start
      run_in_container(script(Shellwords.join(command)), tty: false)
    end

    def clean(clean_volumes: false)
      @services.each(&:clean)
      @network.clean
      @volumes.each(&:clean) if clean_volumes
    end

    def update(skip: [])
      raise_problems
      [
        *@services.collect { |s| s.update(skip: skip) },
        *@container.update(skip: skip),
      ]
    end

    private

    def start
      raise_problems
      @warnings.each { |warning| stderr.puts("Warning: #{warning}") }
      download_missing
      start_services
    end

    def raise_problems
      raise Error, @problems.join("\n") if @problems.any?
    end

    def run_in_container(script, tty:)
      ssh_volumes, ssh_env = ssh_agent_access
      @container.run_and_attach('bash', '-c', script,
        env: @env_variables.merge(ssh_env),
        network: @network,
        volumes: [*@volumes, *ssh_volumes],
        working_dir: @working_dir,
        allow_failure: true,
        tty: tty,
      )
    end

    # The bash script that runs the given command in the container:
    #
    # 1. Waits until all services accept connections, like a GitLab runner does.
    # 2. Runs before_shell, the command and after_shell, and exits with the command's status.
    #    Without saving it, an `after_shell` entry would determine the exit status, and
    #    failures would go unnoticed.
    # 3. Gives files the container created in the project back to the host user, since
    #    the container usually runs as root.
    def script(command)
      [
        *wait_for_services,
        *@before_shell,
        command,
        '__rascal_status=$?',
        *@after_shell,
        *fix_ownership,
        'exit $__rascal_status',
      ].join(';')
    end

    def wait_for_services
      waits = @services.flat_map do |service|
        service.ports.collect { |port| "__rascal_wait_for #{Shellwords.escape(service.aliases.first)} #{port}" }
      end
      waits.any? ? [WAIT_FOR_FUNCTION, *waits] : []
    end

    def fix_ownership
      uid = Process.uid
      return [] if uid == 0 || @working_dir.nil?

      ["find #{Shellwords.escape(@working_dir)} -xdev -user 0 -exec chown -h #{uid}:#{Process.gid} {} + 2>/dev/null"]
    end

    # Volumes and variables that give the container access to the host's SSH agent.
    def ssh_agent_access
      socket = ENV['SSH_AUTH_SOCK']
      return [[], {}] unless @ssh_agent && socket && !socket.empty?

      if RUBY_PLATFORM.include?('darwin')
        socket = DOCKER_DESKTOP_SSH_AGENT_SOCKET
      elsif !File.socket?(socket)
        return [[], {}]
      end

      volumes = [Docker::Volume::Bind.new(socket, SSH_AGENT_SOCKET)]
      known_hosts = File.join(Dir.home, '.ssh', 'known_hosts')
      if File.file?(known_hosts)
        volumes << Docker::Volume::Bind.new(known_hosts, '/etc/ssh/ssh_known_hosts', read_only: true)
      end
      [volumes, { 'SSH_AUTH_SOCK' => SSH_AGENT_SOCKET }]
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
