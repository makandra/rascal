require 'json'
# Runs the real rascal executable against a real Docker daemon.
# Only covers key paths and what mocked tests cannot show. Details belong in unit specs.
describe 'rascal run' do

  def create_job_project
    create_project(<<~YAML)
      job:
        image: #{IntegrationHelpers::JOB_IMAGE}
    YAML
  end

  it 'runs a command in the job image, with the project mounted as its working directory' do
    create_project(<<~YAML)
      variables:
        GREETING: hello
      job:
        image: #{IntegrationHelpers::JOB_IMAGE}
        variables:
          MESSAGE: $GREETING from $CI_JOB_NAME
    YAML
    File.write(File.join(project_dir, 'from-host.txt'), "written on the host\n")

    result = rascal!('run', 'job', '--', 'bash', '-c', 'pwd; cat from-host.txt; echo "$MESSAGE"; echo "written in the container" > from-container.txt')

    expect(result.stdout).to include("/repo\nwritten on the host\nhello from job\n")
    expect(File.read(File.join(project_dir, 'from-container.txt'))).to eq "written in the container\n"
  end

  it 'gives files the container created in the project to the host user' do
    skip 'only applies when not running as root' if Process.uid == 0
    create_job_project

    rascal!('run', 'job', '--', 'bash', '-c', 'mkdir -p created/nested && touch created/nested/file')

    expect(File.stat(File.join(project_dir, 'created/nested/file')).uid).to eq Process.uid
    expect(File.stat(File.join(project_dir, 'created')).uid).to eq Process.uid
  end

  it "gives the command access to the host's SSH agent" do
    Dir.mktmpdir do |dir|
      socket = File.join(dir, 'agent.sock')
      agent_pid = Process.spawn('ssh-agent', '-D', '-a', socket, out: File::NULL, err: File::NULL)
      begin
        50.times { File.socket?(socket) ? break : sleep(0.1) }
        expect(File.socket?(socket)).to be(true), 'ssh-agent did not start'
        create_project(<<~YAML)
          .rascal:
            ssh_agent: true
          job:
            image: #{IntegrationHelpers::JOB_IMAGE}
        YAML

        result = rascal!('run', 'job', '--', 'bash', '-c', 'test -S "$SSH_AUTH_SOCK" && echo "agent at $SSH_AUTH_SOCK"', env: { 'SSH_AUTH_SOCK' => socket })

        expect(result.stdout).to include("agent at /run/rascal/ssh-agent.sock\n")
      ensure
        Process.kill('TERM', agent_pid)
        Process.wait(agent_pid)
      end
    end
  end

  it 'removes the container of a command when rascal is stopped' do
    create_job_project
    pid = Process.spawn(RbConfig.ruby, "-I#{IntegrationHelpers::LIB}", IntegrationHelpers::RASCAL, 'run', 'job', '--', 'sleep', '60',
      chdir: project_dir, out: File::NULL, err: File::NULL)
    run_containers = -> { docker('ps', '--all', '--quiet', '--filter', "name=rascal-#{project_name}-job-run-").split }
    100.times { run_containers.call.empty? ? sleep(0.1) : break }
    expect(run_containers.call.size).to eq 1

    Process.kill('TERM', pid)
    Process.wait(pid)

    expect($?.exitstatus).to eq 143
    expect(run_containers.call).to eq []
  end

  it 'passes stdin to the command' do
    create_job_project

    result = rascal!('run', 'job', '--', 'cat', stdin: "piped in\n")

    expect(result.stdout).to eq "piped in\n"
  end

  it 'starts an environment with services from several commands at once' do
    create_project(<<~YAML)
      job:
        image: #{IntegrationHelpers::JOB_IMAGE}
        services:
          - name: #{IntegrationHelpers::REDIS_IMAGE}
            alias: redis
    YAML

    results = 3.times.collect { Thread.new { rascal('run', 'job', '--', 'true') } }.collect(&:value)

    expect(results.collect(&:exit_code)).to eq [0, 0, 0]
  end

  it 'runs the command with a shell entrypoint like bash -lc' do
    create_project(<<~YAML)
      job:
        image:
          name: #{IntegrationHelpers::JOB_IMAGE}
          entrypoint: ['bash', '-lc']
    YAML

    result = rascal('run', 'job', '--', 'bash', '-c', 'echo ran; exit 3')

    expect(result.stdout).to eq "ran\n"
    expect(result.exit_code).to eq 3
  end

  it 'exits with the status of the command' do
    create_job_project

    expect(rascal('run', 'job', '--', 'bash', '-c', 'exit 3').exit_code).to eq 3
  end

  it 'passes arguments with spaces and shell metacharacters through unchanged' do
    create_job_project

    result = rascal!('run', 'job', '--', 'printf', '[%s]\n', 'a b', '$HOME', "it's; done")

    expect(result.stdout).to include("[a b]\n[$HOME]\n[it's; done]\n")
  end

  it 'runs before_shell and after_shell around the command, keeping its exit status, even after entries with & or a comment' do
    create_project(<<~YAML)
      .rascal:
        before_shell:
          - echo before
          - sleep 0 &
          - true # a comment
        after_shell:
          - echo after
      job:
        image: #{IntegrationHelpers::JOB_IMAGE}
    YAML

    result = rascal('run', 'job', '--', 'bash', '-c', 'echo command; exit 4')

    expect(result.stdout).to include("before\ncommand\nafter\n")
    expect(result.exit_code).to eq 4
  end

  it 'keeps named volumes between runs' do
    create_project(<<~YAML)
      .rascal:
        volumes:
          cache: /cache
      job:
        image: #{IntegrationHelpers::JOB_IMAGE}
    YAML

    rascal!('run', 'job', '--', 'bash', '-c', 'echo kept > /cache/file')
    result = rascal!('run', 'job', '--', 'cat', '/cache/file')

    expect(result.stdout).to include("kept\n")
  end

  describe 'with services' do

    # Sends one command to Redis using bash's /dev/tcp, and prints the last line of the reply.
    # Does not wait for Redis to accept connections, since rascal does that.
    def redis_command(command, reply_lines: 1)
      <<~BASH
        exec 3<>/dev/tcp/redis/6379
        printf '%s\\r\\n' '#{command}' >&3
        for line in $(seq #{reply_lines}); do read -r -t 5 reply <&3; done
        echo "reply: ${reply%$'\\r'}"
      BASH
    end

    before do
      create_project(<<~YAML)
        .rascal:
          volumes:
            cache: /cache
        job:
          image: #{IntegrationHelpers::JOB_IMAGE}
          services:
            - name: #{IntegrationHelpers::REDIS_IMAGE}
              alias: redis
      YAML
    end

    it 'starts services the job reaches by their alias, and keeps them running between runs' do
      rascal!('run', 'job', '--', 'bash', '-c', redis_command('SET greeting hello'))
      result = rascal!('run', 'job', '--', 'bash', '-c', redis_command('GET greeting', reply_lines: 2))

      expect(result.stdout).to include("reply: hello\n")
    end

    it 'lets a second command wait for services that the first one is still starting' do
      create_project(<<~YAML)
        job:
          image: #{IntegrationHelpers::JOB_IMAGE}
          services:
            - name: #{IntegrationHelpers::REDIS_IMAGE}
              alias: redis
              command: ['sh', '-c', 'sleep 3; exec redis-server']
      YAML
      connect = ['bash', '-c', '(exec 3<>/dev/tcp/redis/6379) && echo connected']

      first = Thread.new { rascal('run', 'job', '--', *connect) }
      sleep 1.5
      second = rascal('run', 'job', '--', *connect)

      expect([first.value.stdout, second.stdout]).to eq ["connected\n", "connected\n"]
    end

    it 'points to the logs of a service that stopped, and shows how it stopped in `status`' do
      create_project(<<~YAML)
        .rascal:
          services_timeout: 2
        job:
          image: #{IntegrationHelpers::JOB_IMAGE}
          services:
            - name: #{IntegrationHelpers::REDIS_IMAGE}
              alias: redis
              command: ['sh', '-c', 'exit 1']
      YAML

      result = rascal('run', 'job', '--', 'true')

      expect(result.stderr).to include('rascal: Service redis does not accept connections on port 6379 after 2 seconds, continuing anyway.')
      expect(result.stderr).to include("Warning: Service redis is not running anymore. See why with `docker logs rascal-#{project_name}-job_redis`")
      status = JSON.parse(rascal!('status', 'job', '--json').stdout)
      expect(status['services'].first).to include('state' => 'exited', 'exit_code' => 1, 'image_present' => true)
      expect(status['network']).to include('exists' => true)
    end

    it 'removes containers, networks and volumes with `clean --all --volumes`' do
      rascal!('run', 'job', '--', 'true')
      expect(docker_resources).to include(
        "rascal-#{project_name}-job_redis",
        "rascal-#{project_name}-job",
        "rascal-#{project_name}-job-builds",
        "rascal-#{project_name}-job-cache",
      )
      # The redis image declares a volume for its data, which Docker creates without a name.
      anonymous_volumes = docker('container', 'inspect', '--format', '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}', "rascal-#{project_name}-job_redis").split
      expect(anonymous_volumes).not_to be_empty

      rascal!('clean', '--all', '--volumes')

      expect(docker_resources).to eq []
      expect(docker('volume', 'ls', '--quiet').split & anonymous_volumes).to eq []
    end

  end

end
