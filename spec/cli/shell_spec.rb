# `rascal shell` needs a terminal, so these specs check the docker commands it calls.
# Starting services and running commands for real is covered by spec/integration.
describe 'rascal shell' do

  it 'downloads missing images of the job and its services' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
        services:
          - name: service-image:latest
            alias: service
    YAML
    docker.image_exists('service-image:latest')

    result = run_rascal!('shell', 'job')

    expect(result.stdout).to include("Downloading image for app-job\n")
    expect(docker.commands).to include('docker pull job-image:latest')
    expect(docker.commands).not_to include('docker pull service-image:latest')
  end

  it 'runs bash in the job image, interactively with a TTY' do
    gitlab_ci_config(<<~YAML)
      .rascal:
        before_shell:
          - bundle check
      job:
        image: job-image:latest
        variables:
          FOO: bar
    YAML

    run_rascal!('shell', 'job')

    expect(docker.commands.last).to match(
      %r{\Adocker container run --rm -a STDOUT -a STDERR -a STDIN --interactive --tty -w /repo -v .*/app:/repo -v rascal-app-job-builds:/builds -e CI=true .* -e FOO=bar --network deadbeef job-image:latest bash -c bundle check;bash;}
    )
  end

  it 'creates and starts service containers with their aliases and commands' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
        services:
          - name: service-image:latest
            alias: service
            command: bin/start
          - registry.example.com/group/postgres:15
    YAML

    result = run_rascal!('shell', 'job')

    expect(docker.commands).to include(
      match(%r{\Adocker container create --name rascal-app-job_service -v .*/app:/repo -v rascal-app-job-builds:/builds .* --network deadbeef --network-alias service service-image:latest bin/start\z}),
      match(%r{\Adocker container create --name rascal-app-job_registry.example.com-group-postgres .* --network-alias registry.example.com-group-postgres --network-alias registry.example.com__group__postgres registry.example.com/group/postgres:15\z}),
      'docker container start 00000001',
      'docker container start 00000002',
    )
    expect(result.stdout).to include("Starting container for app-job_service\nStarting container for app-job_registry.example.com-group-postgres\n")
  end

  it "explains why it cannot start a job's environment" do
    gitlab_ci_config(<<~YAML)
      job:
        script: rake
    YAML

    result = run_rascal('shell', 'job')

    expect(result.exit_code).not_to eq 0
    expect(result.stderr).to include("Job 'job' has no image.")
    expect(docker.commands).to eq []
  end

  describe 'with an existing service container' do

    before do
      gitlab_ci_config(<<~YAML)
        job:
          image: job-image:latest
          services:
            - name: service-image:latest
              alias: service
      YAML
    end

    it 'disconnects it from the network before starting it again' do
      docker.container_exists('rascal-app-job_service')

      run_rascal!('shell', 'job')

      expect(docker.commands).to include("docker network disconnect deadbeef #{docker.container_id('rascal-app-job_service')}")
      expect(docker.commands).not_to include(match(/container create/))
    end

    it 'recreates it when its network no longer exists' do
      docker.container_exists('rascal-app-job_service', network_id: 'a-network-that-is-gone')
      old_id = docker.container_id('rascal-app-job_service')

      result = run_rascal!('shell', 'job')

      expect(result.stdout).to include('Removing container for app-job_service, its network no longer exists')
      expect(docker.commands).to include("docker container rm --volumes #{old_id}", match(/container create --name rascal-app-job_service/))
    end

    it 'keeps it when it is attached to the current network' do
      docker.container_exists('rascal-app-job_service', network_id: DockerMockInterface::NETWORK_ID)

      result = run_rascal!('shell', 'job')

      expect(result.stdout).not_to include('its network no longer exists')
      expect(docker.commands).not_to include(match(/container (rm|create)/))
    end

    it 'leaves it alone when it is running' do
      docker.container_exists('rascal-app-job_service', running: true)

      result = run_rascal!('shell', 'job')

      expect(result.stdout).not_to include('Starting container')
      expect(docker.commands).not_to include(match(/container (start|create|rm)/))
    end

  end

end
