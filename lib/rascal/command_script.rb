require 'shellwords'

module Rascal
  # The bash script that runs a command in a job's container:
  #
  # 1. Waits until services that may not be ready yet accept connections, like a GitLab runner does.
  # 2. Lets Git trust the project, which belongs to another user than the container's.
  # 3. Runs before_shell, the command and after_shell, and exits with the command's status.
  #    Each on its own line, so entries may end in `&` or a comment. Without saving the status,
  #    an after_shell entry would determine it, and failures would go unnoticed.
  # 4. Gives files the command created in the project back to their owner, since the container
  #    usually runs as root.
  class CommandScript
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

    # `command` is a bash command line. `waits` are [host, ports] pairs, for which it waits up to
    # `wait_timeout` seconds each. `owner` is the [uid, gid] that should own new files in
    # `working_dir`, or nil to leave them as they are.
    def initialize(command, working_dir:, before_shell: [], after_shell: [], waits: [], wait_timeout: 30, owner: nil)
      @command = command
      @working_dir = working_dir
      @before_shell = before_shell
      @after_shell = after_shell
      @waits = waits.reject { |_host, ports| ports.empty? }
      @wait_timeout = wait_timeout
      @owner = owner
    end

    def to_s
      [
        *wait_for_services,
        *trust_project_for_git,
        *@before_shell,
        @command,
        '__rascal_status=$?',
        *@after_shell,
        *fix_ownership,
        'exit $__rascal_status',
      ].join("\n")
    end

    private

    def wait_for_services
      return [] if @waits.empty?

      [WAIT_FOR_FUNCTION, *@waits.collect { |host, ports| "__rascal_wait_for #{Shellwords.escape(host)} #{@wait_timeout.to_i} #{ports.join(' ')}" }]
    end

    # Git refuses a repository that belongs to another user ("detected dubious ownership").
    # The project is mounted on purpose, so trust it in the container's global Git config,
    # which goes away with the container. Older Git, as in Ubuntu 22.04, ignores
    # safe.directory from anywhere else.
    def trust_project_for_git
      return [] if @working_dir.nil?

      dir = Shellwords.escape(@working_dir)
      ["if command -v git > /dev/null 2>&1 && ! git config --global --get-all safe.directory 2> /dev/null | grep -qxF #{dir}; " \
       "then git config --global --add safe.directory #{dir} 2> /dev/null; fi"]
    end

    # Only when the project appears in the container as owned by that user, so it leaves a
    # differently mapped project alone.
    def fix_ownership
      return [] if @owner.nil? || @working_dir.nil?

      uid, gid = @owner
      dir = Shellwords.escape(@working_dir)
      ["[ \"$(stat -c %u #{dir} 2>/dev/null)\" = #{uid} ] && find #{dir} -xdev -user 0 -exec chown -h #{uid}:#{gid} {} + 2>/dev/null"]
    end
  end
end
