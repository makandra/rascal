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
        sleep 0.1 until File.socket?(socket)
        create_job_project

        result = rascal!('run', 'job', '--', 'bash', '-c', 'test -S "$SSH_AUTH_SOCK" && echo "agent at $SSH_AUTH_SOCK"', env: { 'SSH_AUTH_SOCK' => socket })

        expect(result.stdout).to include("agent at /run/rascal/ssh-agent.sock\n")
      ensure
        Process.kill('TERM', agent_pid)
        Process.wait(agent_pid)
      end
    end
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

  it 'runs before_shell and after_shell around the command, keeping its exit status' do
    create_project(<<~YAML)
      .rascal:
        before_shell:
          - echo before
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
