require 'socket'
require 'fileutils'

# Running commands for real (output, exit status, quoting, services) is covered by
# spec/integration. These specs cover what happens before anything runs.
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

  it "explains why it cannot start a job's environment" do
    gitlab_ci_config(<<~YAML)
      deploy:
        image: $CI_REGISTRY_IMAGE/deploy:latest
    YAML

    result = run_rascal('run', 'deploy', '--', 'true')

    expect(result.exit_code).not_to eq 0
    expect(result.stderr).to include("The image of job 'deploy' ($CI_REGISTRY_IMAGE/deploy:latest) uses the undefined variable CI_REGISTRY_IMAGE.")
    expect(docker.commands).to eq []
  end

  it 'suggests docker login when the image cannot be pulled for lack of credentials' do
    gitlab_ci_config(<<~YAML)
      job:
        image: registry.example.com/group/app:1.0
    YAML
    docker.pull_fails('registry.example.com/group/app:1.0', 'Error response from daemon: unauthorized: HTTP Basic: Access denied')

    result = run_rascal('run', 'job', '--', 'true')

    expect(result.exit_code).not_to eq 0
    expect(result.stderr).to include('Log in with `docker login registry.example.com`, then try again.')
  end

  it 'warns about variables that reference undefined variables, and runs anyway' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
        variables:
          DATABASE_URL: postgres://user:$DB_PASSWORD@db
    YAML

    result = run_rascal('run', 'job', '--', 'true')

    expect(result.exit_code).to eq 0
    expect(result.stderr).to include('Warning: Variable DATABASE_URL references DB_PASSWORD, which is undefined')
    expect(docker.commands).to include(match(/container run/))
  end

  describe 'the script it runs in the container' do

    def container_script
      run_rascal!('run', 'job', '--', 'rake')
      docker.history.last.reject { |part| part.is_a?(Hash) }.last
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

      expect(container_script).to match(/\A__rascal_wait_for\(\) \{.*\};__rascal_wait_for db 30 3306 33060;bundle check;rake;/)
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

      expect(container_script).to include(';__rascal_wait_for db 120 3306;')
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
        ";[ \"$(stat -c %u /repo 2>/dev/null)\" = #{Process.uid} ] && find /repo -xdev -user 0 -exec chown -h #{Process.uid}:#{Process.gid} {} + 2>/dev/null;exit $__rascal_status"
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
      docker.commands.last
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
      expect(docker.commands.last).not_to include('ssh-agent.sock')
    end

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
