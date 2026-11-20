require 'shellwords'
require 'tmpdir'

module Rascal
  class Environment
    include IOHelper

    # Where the host's SSH agent socket appears in the container.
    SSH_AGENT_SOCKET = '/run/rascal/ssh-agent.sock'

    # Docker Desktop's path for the host's SSH agent. Sockets from macOS cannot be mounted directly.
    DOCKER_DESKTOP_SSH_AGENT_SOCKET = '/run/host-services/ssh-auth.sock'

    # How long to wait by default for a service to accept connections before running the command anyway.
    DEFAULT_SERVICES_TIMEOUT = 30

    # A bash function that waits until a host accepts TCP connections on one of the given ports:
    # __rascal_wait_for HOST TIMEOUT_SECONDS PORT...
    WAIT_FOR_FUNCTION = <<~BASH.gsub(/\n\s*/, ' ').strip
      __rascal_wait_for() {
        local host=$1 timeout=$2 deadline=$((SECONDS + $2)) port; shift 2;
        while ((SECONDS < deadline)); do
          for port in "$@"; do (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null && return; done;
          sleep 0.1;
        done;
        echo "rascal: Service $host does not accept connections on port $* after $timeout seconds, continuing anyway. If it listens on another port, set HEALTHCHECK_TCP_PORT in its variables. If it needs more time, set services_timeout in the .rascal block." >&2;
      }
    BASH

    attr_reader :name, :network, :container, :env_variables, :services, :volumes, :working_dir, :before_shell,
      :problems, :warnings, :services_timeout

    # `problems` prevent the environment from starting, but not from being cleaned.
    # `warnings` are shown before starting it.
    # With `ssh_agent`, the host's SSH agent and known hosts are available in the container,
    # so it can fetch private dependencies over SSH. `services_timeout` is how many seconds to
    # wait for services to accept connections.
    def initialize(full_name, name:, image:, entrypoint: nil, env_variables: {}, services: [], volumes: [], before_shell: [], after_shell: [], working_dir: nil, problems: [], warnings: [], ssh_agent: false, services_timeout: DEFAULT_SERVICES_TIMEOUT)
      @name = name
      @network = Docker::Network.new(full_name)
      @container = Docker::Container.new(full_name, image, entrypoint: entrypoint)
      @env_variables = env_variables
      @services = services
      @volumes = volumes
      @working_dir = working_dir
      @before_shell = before_shell
      @after_shell = after_shell
      @problems = problems
      @warnings = warnings
      @ssh_agent = ssh_agent
      @services_timeout = services_timeout
    end

    # `env`, `unset_env` and `ssh_agent` change the container for this command only, like for
    # updating dependencies. Services keep their variables. `ssh_agent` overrides the config's
    # setting unless it is nil.
    def run_shell(env: {}, unset_env: [], ssh_agent: nil)
      starting_services = start
      run_in_container(script('bash', starting_services), tty: true, env: env, unset_env: unset_env, ssh_agent: ssh_agent).tap { report_stopped_services }
    end

    # Runs a single command in the environment, without a TTY, and returns its
    # Process::Status. Unlike #run_shell this is suitable for non-interactive
    # use (scripts, CI-like runs, AI agents), which need the command's real
    # exit status.
    #
    # The command is a list of arguments, which is escaped before being handed
    # to bash, so arguments may contain spaces and shell metacharacters. Use
    # e.g. `bash -c "foo && bar"` to run something the shell must interpret.
    # See #run_shell for the keyword arguments.
    def run_command(*command, env: {}, unset_env: [], ssh_agent: nil)
      starting_services = start
      run_in_container(script(Shellwords.join(command), starting_services), tty: false, forward_stdin: stdin_redirected?,
        env: env, unset_env: unset_env, ssh_agent: ssh_agent).tap { report_stopped_services }
    end

    def clean(clean_volumes: false)
      @container.clean_runs
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

    # Returns the services that may not be ready yet: those it started, and those another
    # command started less than services_timeout ago.
    def start
      raise_problems
      @warnings.each { |warning| warning(warning) }
      download_missing
      started = start_services
      @services.select { |service| started.include?(service) || service.starting?(@services_timeout) }
    end

    # Only passes stdin on when it comes from a file or pipe, like `rascal run job -- psql < dump.sql`,
    # or from a socket with input waiting, like from Node's child_process. A terminal, or a socket
    # that stays open without input, would make commands that read stdin hang.
    def stdin_redirected?
      stat = stdin.stat
      stat.pipe? || stat.file? || (stat.socket? && !IO.select([stdin], nil, nil, 0).nil?)
    rescue NoMethodError, IOError, SystemCallError
      false
    end

    # A service that stopped, typically because of bad settings, makes commands fail in
    # confusing ways, so point to its output.
    def report_stopped_services
      @services.reject(&:running?).each do |service|
        warning("Service #{service.aliases.first} is not running anymore. See why with `docker logs #{service.container.prefixed_name}`, " \
                    "then fix its settings and run `rascal clean #{@name}`.")
      end
    end

    def raise_problems
      raise Error, @problems.join("\n") if @problems.any?
    end

    def run_in_container(script, tty:, env:, unset_env:, ssh_agent:, forward_stdin: tty)
      ssh_volumes, ssh_env = ssh_agent_access(ssh_agent.nil? ? @ssh_agent : ssh_agent)
      @container.run_and_attach('bash', '-c', script,
        env: @env_variables.except(*unset_env).merge(env, ssh_env),
        network: @network,
        volumes: [*@volumes, *ssh_volumes],
        working_dir: @working_dir,
        tty: tty,
        forward_stdin: forward_stdin,
      )
    end

    # The bash script that runs the given command in the container:
    #
    # 1. Waits until services that may not be ready yet accept connections, like a GitLab runner does.
    # 2. Runs before_shell, the command and after_shell, and exits with the command's status.
    #    Each on its own line, so entries may end in `&` or a comment.
    #    Without saving it, an `after_shell` entry would determine the exit status, and
    #    failures would go unnoticed.
    # 3. Gives files the container created in the project back to the host user, since
    #    the container usually runs as root.
    def script(command, starting_services)
      [
        *wait_for(starting_services),
        *@before_shell,
        command,
        '__rascal_status=$?',
        *@after_shell,
        *fix_ownership,
        'exit $__rascal_status',
      ].join("\n")
    end

    def wait_for(services)
      waits = services.filter_map do |service|
        ports = service.ports
        "__rascal_wait_for #{Shellwords.escape(service.aliases.first)} #{@services_timeout.to_i} #{ports.join(' ')}" if ports.any?
      end
      waits.any? ? [WAIT_FOR_FUNCTION, *waits] : []
    end

    # Only when the project appears in the container as owned by the host user. With rootless
    # Docker, the host user is root in the container, and with Docker Desktop for Mac,
    # ownership is mapped already.
    def fix_ownership
      uid = Process.uid
      return [] if uid == 0 || @working_dir.nil? || RUBY_PLATFORM.include?('darwin')

      dir = Shellwords.escape(@working_dir)
      ["[ \"$(stat -c %u #{dir} 2>/dev/null)\" = #{uid} ] && find #{dir} -xdev -user 0 -exec chown -h #{uid}:#{Process.gid} {} + 2>/dev/null"]
    end

    # Volumes and variables that give the container access to the host's SSH agent.
    def ssh_agent_access(enabled)
      return [[], {}] unless enabled

      socket = ENV['SSH_AUTH_SOCK'].to_s
      if Docker.interface.run('info', '--format', '{{.OperatingSystem}}', output: :text, allow_failure: true).to_s.include?('Docker Desktop')
        # Docker Desktop runs in a VM and provides the host's agent at a fixed path.
        socket = DOCKER_DESKTOP_SSH_AGENT_SOCKET
      elsif socket.empty? || !File.socket?(socket)
        warning('ssh_agent is enabled, but there is no SSH agent at SSH_AUTH_SOCK. Start one with `eval $(ssh-agent)` and `ssh-add`.')
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

    # Several commands may start the same environment at once, like parallel test runs.
    # A lock keeps them from creating the same network and services, or disconnecting
    # a service another one just started.
    def start_services
      with_start_lock do
        @network.create unless @network.exists?
        @services.select { |service| service.start_if_stopped(network: @network) }
      end
    end

    def with_start_lock
      File.open(File.join(Dir.tmpdir, "#{@container.prefixed_name}.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end
  end
end
