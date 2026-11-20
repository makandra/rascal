require 'socket'
require 'fileutils'

# How `rascal run` runs a command: arguments and options, the script around the command,
# stdin, entrypoints, the SSH agent and variables for one command. Starting the environment
# is covered by starting_an_environment_spec.rb, running commands for real by spec/integration.
describe 'rascal run' do

  it 'complains about a missing command' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
    YAML

    result = run_rascal('run', 'job')

    expect(result.exit_code).not_to eq 0
    expect(result.stderr).to include('Missing command. Example: rascal run job -- bundle exec rake')
    expect(docker.commands).not_to include(match(/container run/))
  end

  it 'complains about an unknown environment, listing the available ones' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
    YAML

    result = run_rascal('run', 'nope', '--', 'rake')

    expect(result.exit_code).not_to eq 0
    expect(result.stderr).to include('Unknown environment nope. Available: job.')
  end

  it 'reports what it does on stderr, and keeps stdout for the command' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
        services:
          - name: redis:7
            alias: redis
    YAML

    result = run_rascal!('run', 'job', '--', 'true')

    expect(result.stderr).to include('Downloading image for app-job', 'Starting container for app-job_redis')
    expect(result.stdout).to eq ''
  end

  it 'passes stdin on only when it comes from a pipe or file, since a terminal or socket may never close' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
    YAML

    run_rascal!('run', 'job', '--', 'true')
    expect(docker.commands.grep(/container run/).last).not_to include('-a STDIN')

    reader, writer = IO.pipe
    writer.close
    run_rascal!('run', 'job', '--', 'psql', stdin: reader)
    expect(docker.commands.grep(/container run/).last).to include('-a STDOUT -a STDERR -a STDIN --interactive -w /repo')
  end

  it 'passes stdin on from a socket only when input is waiting, like from Node child_process' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
    YAML
    idle, _other_end = UNIXSocket.pair
    with_input, sender = UNIXSocket.pair
    sender.write("input\n")
    sender.close

    run_rascal!('run', 'job', '--', 'psql', stdin: idle)
    expect(docker.commands.grep(/container run/).last).not_to include('-a STDIN')

    run_rascal!('run', 'job', '--', 'psql', stdin: with_input)
    expect(docker.commands.grep(/container run/).last).to include('-a STDIN --interactive')
  end

  describe 'with a shell as entrypoint' do

    def arguments_after_image(image)
      run_rascal!('run', 'job', '--', 'true')
      command = docker.history.reverse.detect { |c| c.include?('run') && c.include?('container') }.reject { |part| part.is_a?(Hash) }
      command.drop(command.index(image) + 1)
    end

    it 'passes the command as one string when the job sets an entrypoint like sh -c, bash -lc or sh -ec' do
      ['-c', '-lc', '-ec'].each do |option|
        gitlab_ci_config(<<~YAML)
          job:
            image:
              name: job-image:latest
              entrypoint: ['/bin/sh', '#{option}']
        YAML

        arguments = arguments_after_image('job-image:latest')

        expect(arguments.size).to eq(2), "for #{option}"
        expect(arguments.first).to eq option
        expect(arguments.last).to start_with('bash -c ')
      end
    end

    it "passes the command as one string when the image's own entrypoint is such a shell" do
      gitlab_ci_config(<<~YAML)
        job:
          image: shell-image:latest
      YAML
      docker.image_exists('shell-image:latest', entrypoint: ['/bin/sh', '-c'])

      arguments = arguments_after_image('shell-image:latest')

      expect(arguments.size).to eq 1
      expect(arguments.last).to start_with('bash -c ')
    end

  end

  it "overrides the image's entrypoint when the job sets one" do
    gitlab_ci_config(<<~YAML)
      job:
        image:
          name: job-image:latest
          entrypoint: ['']
    YAML

    run_rascal!('run', 'job', '--', 'true')

    expect(docker.commands.grep(/container run/).last).to include("-a STDERR --entrypoint  -w /repo ")
  end

  describe 'the script it runs in the container' do

    def container_script
      run_rascal!('run', 'job', '--', 'rake')
      docker.history.reverse.detect { |command| command.include?('run') && command.include?('container') }.reject { |part| part.is_a?(Hash) }.last
    end

    it 'first waits until services it started accept connections on one of their exposed TCP ports' do
      gitlab_ci_config(<<~YAML)
        .rascal:
          before_shell:
            - bundle check
        job:
          image: job-image:latest
          services:
            - name: mysql:5.7
              alias: db
      YAML
      docker.image_exists('mysql:5.7', exposed_ports: ['3306/tcp', '33060/tcp', '53/udp'])

      expect(container_script).to match(/\A__rascal_wait_for\(\) \{.*\}\n__rascal_wait_for db 30 3306 33060\nbundle check\nrake\n/)
    end

    it 'waits for HEALTHCHECK_TCP_PORT instead, and as long as services_timeout says' do
      gitlab_ci_config(<<~YAML)
        .rascal:
          services_timeout: 120
        job:
          image: job-image:latest
          services:
            - name: mysql:5.7
              alias: db
              variables:
                HEALTHCHECK_TCP_PORT: '3306'
      YAML
      docker.image_exists('mysql:5.7', exposed_ports: ['3306/tcp', '33060/tcp'])

      expect(container_script).to include("\n__rascal_wait_for db 120 3306\n")
    end

    it 'waits for services another command started less than services_timeout ago' do
      gitlab_ci_config(<<~YAML)
        job:
          image: job-image:latest
          services:
            - name: mysql:5.7
              alias: db
      YAML
      docker.image_exists('mysql:5.7', exposed_ports: ['3306/tcp'])
      docker.container_exists('rascal-app-job_db', running: true, started_at: Time.now - 5)

      expect(container_script).to include("\n__rascal_wait_for db 30 3306\n")
    end

    it 'does not wait for services that were already running' do
      gitlab_ci_config(<<~YAML)
        job:
          image: job-image:latest
          services:
            - name: mysql:5.7
              alias: db
      YAML
      docker.image_exists('mysql:5.7', exposed_ports: ['3306/tcp'])
      docker.container_exists('rascal-app-job_db', running: true)

      expect(container_script).not_to include('__rascal_wait_for')
    end

    it 'gives files the container created in the project back to the host user' do
      skip 'only applies when not running as root' if Process.uid == 0
      gitlab_ci_config(<<~YAML)
        job:
          image: job-image:latest
      YAML

      expect(container_script).to end_with(
        "\n[ \"$(stat -c %u /repo 2>/dev/null)\" = #{Process.uid} ] && find /repo -xdev -user 0 -exec chown -h #{Process.uid}:#{Process.gid} {} + 2>/dev/null\nexit $__rascal_status"
      )
    end

  end

  describe 'SSH agent' do

    around do |example|
      Dir.mktmpdir do |dir|
        @agent_socket = File.join(dir, 'agent.sock')
        @home = File.join(dir, 'home')
        FileUtils.mkdir_p(File.join(@home, '.ssh'))
        File.write(File.join(@home, '.ssh', 'known_hosts'), "example.com ssh-ed25519 AAAA\n")
        server = UNIXServer.new(@agent_socket)
        original_home = ENV['HOME']
        ENV['HOME'] = @home
        example.run
      ensure
        ENV['HOME'] = original_home
        server&.close
      end
    end

    def docker_run_command
      run_rascal!('run', 'job', '--', 'bundle', 'install')
      docker.commands.grep(/container run/).last
    end

    it "gives the container the host's SSH agent and known hosts when the .rascal block enables it" do
      ENV['SSH_AUTH_SOCK'] = @agent_socket
      gitlab_ci_config(<<~YAML)
        .rascal:
          ssh_agent: true
        job:
          image: job-image:latest
      YAML

      expect(docker_run_command).to include(
        "-v #{@agent_socket}:/run/rascal/ssh-agent.sock",
        "-v #{@home}/.ssh/known_hosts:/etc/ssh/ssh_known_hosts:ro",
        '-e SSH_AUTH_SOCK=/run/rascal/ssh-agent.sock',
      )
    end

    it "uses Docker Desktop's path for the agent, since it runs Docker in a VM" do
      ENV['SSH_AUTH_SOCK'] = '/private/tmp/com.apple.launchd.abc/Listeners'
      docker.operating_system = 'Docker Desktop'
      gitlab_ci_config(<<~YAML)
        .rascal:
          ssh_agent: true
        job:
          image: job-image:latest
      YAML

      expect(docker_run_command).to include('-v /run/host-services/ssh-auth.sock:/run/rascal/ssh-agent.sock')
    end

    it 'gives a single command the SSH agent with --ssh-agent' do
      ENV['SSH_AUTH_SOCK'] = @agent_socket
      gitlab_ci_config(<<~YAML)
        job:
          image: job-image:latest
      YAML

      run_rascal!('run', 'job', '--ssh-agent', '--', 'bundle', 'update')
      run_rascal!('run', 'job', '--', 'bundle', 'exec', 'rspec')

      updating, testing = docker.commands.grep(/container run/)
      expect(updating).to include("-v #{@agent_socket}:/run/rascal/ssh-agent.sock")
      expect(testing).not_to include('ssh')
    end

    it 'keeps the SSH agent away from a single command with --no-ssh-agent, even if the config enables it' do
      ENV['SSH_AUTH_SOCK'] = @agent_socket
      gitlab_ci_config(<<~YAML)
        .rascal:
          ssh_agent: true
        job:
          image: job-image:latest
      YAML

      run_rascal!('run', 'job', '--no-ssh-agent', '--', 'bundle', 'exec', 'rspec')

      expect(docker.commands.grep(/container run/).last).not_to include('ssh')
    end

    it 'does not give the container the SSH agent unless enabled, since code in the container could use its keys' do
      ENV['SSH_AUTH_SOCK'] = @agent_socket
      gitlab_ci_config(<<~YAML)
        job:
          image: job-image:latest
      YAML

      expect(docker_run_command).not_to include('ssh')
    end

    it 'warns when the SSH agent is enabled but there is none' do
      gitlab_ci_config(<<~YAML)
        .rascal:
          ssh_agent: true
        job:
          image: job-image:latest
      YAML

      result = run_rascal!('run', 'job', '--', 'true')

      expect(result.stderr).to include('Warning: ssh_agent is enabled, but there is no SSH agent at SSH_AUTH_SOCK.')
      expect(docker.commands.grep(/container run/).last).not_to include('ssh-agent.sock')
    end

  end

  describe 'changing variables for one command' do

    before do
      gitlab_ci_config(<<~YAML)
        job:
          image: job-image:latest
          variables:
            FOO: foo
          services:
            - name: service-image:latest
              alias: service
      YAML
    end

    it 'sets variables with --env and removes them with --unset-env, for that command only' do
      run_rascal!('run', 'job', '--env', 'FOO=changed', '--env', 'BAR=a=b', '--unset-env', 'CI', '--unset-env', 'GITLAB_CI', '--', 'bundle', 'update')
      run_rascal!('run', 'job', '--', 'bundle', 'exec', 'rspec')

      updating, testing = docker.commands.grep(/container run/)
      expect(updating).to include('-e FOO=changed', '-e BAR=a=b')
      expect(updating).not_to include('-e CI=', '-e GITLAB_CI=')
      expect(testing).to include('-e FOO=foo', '-e CI=true', '-e GITLAB_CI=true')
      expect(docker.commands.grep(/container create/).last).to include('-e FOO=foo', '-e CI=true')
    end

    it 'complains about --env without a value, and --unset-env with one' do
      missing_value = run_rascal('run', 'job', '--env', 'FOO', '--', 'true')
      unexpected_value = run_rascal('run', 'job', '--unset-env', 'CI=true', '--', 'true')

      expect(missing_value.stderr).to include('Use --env NAME=VALUE, like --env RAILS_ENV=test.')
      expect(unexpected_value.stderr).to include('Use --unset-env NAME, like --unset-env CI.')
      expect(docker.commands.grep(/container run/)).to be_empty
    end

    it 'takes --env before and after the environment name' do
      run_rascal!('run', '--env', 'A=1', 'job', '--env', 'B=2', '--', 'true')

      expect(docker.commands.grep(/container run/).last).to include('-e A=1', '-e B=2')
    end

  end

  it 'accepts options before or after the environment name, but not after --' do
    other_project = File.join(@tmp_dir, 'other')
    Dir.mkdir(other_project)
    File.write(File.join(other_project, '.gitlab-ci.yml'), "other-job:\n  image: other-image:latest\n")

    run_rascal!('run', 'other-job', '-c', other_project, '--', 'ls', '-c', 'x')

    expect(docker.commands.grep(/container run/).last).to match(/other-image:latest bash -c ls -c x\n/)
  end

  it 'runs a command without a leading -- as it is, even when it contains --' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
    YAML

    run_rascal!('run', 'job', 'git', 'checkout', '--', 'file')

    expect(docker.commands.grep(/container run/).last).to match(/job-image:latest bash -c git checkout -- file\n/)
  end

  it 'complains about options after the environment name without --, instead of running them' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
    YAML

    result = run_rascal('run', 'job', '--ssh-agent', 'bundle', 'update')

    expect(result.exit_code).not_to eq 0
    expect(result.stderr).to include("Put -- between rascal's options and the command")
    expect(docker.commands.grep(/container run/)).to be_empty
  end

  it 'complains about unknown options, instead of running them' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
    YAML

    result = run_rascal('run', 'job', '--bogus', '--', 'true')

    expect(result.exit_code).not_to eq 0
    expect(result.stderr).to include('Unknown switches "--bogus"')
    expect(docker.commands.grep(/container run/)).to be_empty
  end

  it 'exits with 128 plus the signal number when the command was killed' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
    YAML
    allow(docker).to receive(:spawn).and_return(instance_double(Process::Status, success?: false, exitstatus: nil, termsig: 9))

    expect(run_rascal('run', 'job', '--', 'sleep', '100').exit_code).to eq 137
  end

end
