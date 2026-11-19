# Runs the real rascal executable against a real Docker daemon.
# Only covers key paths and what mocked tests cannot show. Details belong in unit specs.
describe 'rascal run' do

  def create_job_project(job_config = '')
    create_project(<<~YAML)
      job:
        image: #{IntegrationHelpers::JOB_IMAGE}
      #{job_config.gsub(/^/, '  ')}
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
    # Waits for Redis to accept connections first.
    def redis_command(command, reply_lines: 1)
      <<~BASH
        for attempt in $(seq 100); do (exec 3<>/dev/tcp/redis/6379) 2>/dev/null && break; sleep 0.1; done
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

      rascal!('clean', '--all', '--volumes')

      expect(docker_resources).to eq []
    end

  end

end
