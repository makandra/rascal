# Starting an environment is the same for `rascal run` and `rascal shell`: download images,
# start services, explain what keeps a job from starting. These specs use `rascal run`.
describe 'starting an environment' do

  it 'downloads missing images of the job and its services' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
        services:
          - name: service-image:latest
            alias: service
    YAML
    docker.image_exists('service-image:latest')

    result = run_rascal!('run', 'job', '--', 'true')

    expect(result.stderr).to include("Downloading image for app-job\n")
    expect(docker.commands).to include('docker pull job-image:latest')
    expect(docker.commands).not_to include('docker pull service-image:latest')
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

    result = run_rascal!('run', 'job', '--', 'true')

    expect(docker.commands).to include(
      match(%r{\Adocker container create --name rascal-app-job_service -v .*/app:/repo -v rascal-app-job-builds:/builds .* --network deadbeef --network-alias service service-image:latest bin/start\z}),
      match(%r{\Adocker container create --name rascal-app-job_registry.example.com-group-postgres .* --network-alias registry.example.com-group-postgres --network-alias registry.example.com__group__postgres registry.example.com/group/postgres:15\z}),
      'docker container start 00000001',
      'docker container start 00000002',
    )
    expect(result.stderr).to include("Starting container for app-job_service\nStarting container for app-job_registry.example.com-group-postgres\n")
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

    it 'connects it to the network again under its aliases before starting it, since Docker forgets the network of a disconnected container' do
      docker.container_exists('rascal-app-job_service')
      id = docker.container_id('rascal-app-job_service')

      run_rascal!('run', 'job', '--', 'true')

      expect(docker.commands).to include(
        "docker network disconnect deadbeef #{id}",
        "docker network connect --alias service deadbeef #{id}",
        "docker container start #{id}",
      )
      expect(docker.commands.index("docker network connect --alias service deadbeef #{id}")).to be < docker.commands.index("docker container start #{id}")
      expect(docker.commands).not_to include(match(/container create/))
    end

    it 'recreates it when its network no longer exists' do
      docker.container_exists('rascal-app-job_service', network_id: 'a-network-that-is-gone')
      old_id = docker.container_id('rascal-app-job_service')

      result = run_rascal!('run', 'job', '--', 'true')

      expect(result.stderr).to include('Removing container for app-job_service, its network no longer exists')
      expect(docker.commands).to include("docker container rm --volumes #{old_id}", match(/container create --name rascal-app-job_service/))
    end

    it 'keeps it when it is attached to the current network' do
      docker.container_exists('rascal-app-job_service', network_id: DockerMockInterface::NETWORK_ID)

      result = run_rascal!('run', 'job', '--', 'true')

      expect(result.stderr).not_to include('its network no longer exists')
      expect(docker.commands).not_to include(match(/container (rm|create)/))
    end

    it 'connects it again when it runs without the network, like after an older rascal restarted it' do
      docker.container_exists('rascal-app-job_service', running: true)
      id = docker.container_id('rascal-app-job_service')

      run_rascal!('run', 'job', '--', 'true')

      expect(docker.commands).to include("docker network connect --alias service deadbeef #{id}")
      expect(docker.commands).not_to include(match(/container (start|create|rm)/))
    end

    it 'leaves it alone when it is running on the network' do
      docker.container_exists('rascal-app-job_service', running: true, network_id: DockerMockInterface::NETWORK_ID)

      result = run_rascal!('run', 'job', '--', 'true')

      expect(result.stderr).not_to include('Starting container')
      expect(docker.commands).not_to include(match(/container (start|create|rm)/))
    end

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

  it 'explains when the image does not exist' do
    gitlab_ci_config(<<~YAML)
      job:
        image: registry.example.com/group/app:1.0
    YAML
    docker.pull_fails('registry.example.com/group/app:1.0', 'Error response from daemon: manifest for registry.example.com/group/app:1.0 not found: manifest unknown: manifest unknown')

    result = run_rascal('run', 'job', '--', 'true')

    expect(result.exit_code).not_to eq 0
    expect(result.stderr).to include('Docker found no image registry.example.com/group/app:1.0 in its registry.')
  end

  it 'passes on other errors from pulling an image unchanged' do
    gitlab_ci_config(<<~YAML)
      job:
        image: registry.example.com/group/app:1.0
    YAML
    docker.pull_fails('registry.example.com/group/app:1.0', 'permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock')

    result = run_rascal('run', 'job', '--', 'true')

    expect(result.exit_code).not_to eq 0
    expect(result.stderr).to include('permission denied while trying to connect to the Docker daemon socket')
    expect(result.stderr).not_to include('docker login')
  end

  it 'does not mistake other errors containing "not found" for a missing image' do
    gitlab_ci_config(<<~YAML)
      job:
        image: registry.example.com/group/app:1.0
    YAML
    docker.pull_fails('registry.example.com/group/app:1.0', 'error getting credentials - err: exec: "docker-credential-desktop": executable file not found in $PATH')

    result = run_rascal('run', 'job', '--', 'true')

    expect(result.exit_code).not_to eq 0
    expect(result.stderr).to include('docker-credential-desktop')
    expect(result.stderr).not_to include('Docker found no image')
  end

  it 'warns about includes it cannot read' do
    gitlab_ci_config(<<~YAML)
      include:
        - project: group/templates
          file: services.yml
      job:
        image: job-image:latest
    YAML

    result = run_rascal!('run', 'job', '--', 'true')

    expect(result.stderr).to include(
      'Warning: rascal cannot read these includes, so config from them is missing: project: group/templates, file: services.yml. ' \
      'If the job needs services or variables from them, set them in the `.rascal` block.'
    )
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

end
