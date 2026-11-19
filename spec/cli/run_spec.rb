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

    it 'first waits until services accept connections on their exposed TCP ports' do
      gitlab_ci_config(<<~YAML)
        .rascal:
          before_shell:
            - bundle check
        job:
          image: job-image:latest
          services:
            - name: redis:7
              alias: redis
      YAML
      docker.image_exists('redis:7', exposed_ports: ['6379/tcp', '53/udp'])

      expect(container_script).to match(/\A__rascal_wait_for\(\) \{.*\};__rascal_wait_for redis 6379;bundle check;rake;/)
    end

    it 'gives files the container created in the project back to the host user' do
      skip 'only applies when not running as root' if Process.uid == 0
      gitlab_ci_config(<<~YAML)
        job:
          image: job-image:latest
      YAML

      expect(container_script).to end_with(";find /repo -xdev -user 0 -exec chown -h #{Process.uid}:#{Process.gid} {} + 2>/dev/null;exit $__rascal_status")
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

    it "gives the container the host's SSH agent and known hosts" do
      ENV['SSH_AUTH_SOCK'] = @agent_socket
      gitlab_ci_config(<<~YAML)
        job:
          image: job-image:latest
      YAML

      expect(docker_run_command).to include(
        "-v #{@agent_socket}:/run/rascal/ssh-agent.sock",
        "-v #{@home}/.ssh/known_hosts:/etc/ssh/ssh_known_hosts:ro",
        '-e SSH_AUTH_SOCK=/run/rascal/ssh-agent.sock',
      )
    end

    it 'does without when there is no agent, or when the .rascal block turns it off' do
      gitlab_ci_config(<<~YAML)
        job:
          image: job-image:latest
      YAML
      expect(docker_run_command).not_to include('ssh')

      ENV['SSH_AUTH_SOCK'] = @agent_socket
      gitlab_ci_config(<<~YAML)
        .rascal:
          ssh_agent: false
        job:
          image: job-image:latest
      YAML
      expect(docker_run_command).not_to include('ssh')
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
