# Removing real containers, networks and volumes is covered by spec/integration.
describe 'rascal clean' do

  before do
    gitlab_ci_config(<<~YAML)
      .rascal:
        volumes:
          cache: /cache
      job:
        image: job-image:latest
        services:
          - name: service-image:latest
            alias: service
      deploy:
        image: $CI_REGISTRY_IMAGE/deploy:latest
    YAML
  end

  it 'removes stopped service containers and the network without stopping anything' do
    docker.container_exists('rascal-app-job_service')

    result = run_rascal!('clean', 'job')

    expect(result.stdout).not_to include('Stopping')
    expect(result.stdout).to include('Removing container for app-job_service')
    expect(docker.commands).to include(match(/container rm --volumes/), match(/network rm/))
  end

  it 'keeps volumes unless asked to remove them' do
    docker.volume_exists('rascal-app-job-cache')

    expect(run_rascal!('clean', 'job').stdout).not_to include('Removing volume')
    expect(run_rascal!('clean', 'job', '--volumes').stdout).to include('Removing volume rascal-app-job-cache')
  end

  it 'cleans all environments, including those whose image cannot be resolved' do
    docker.container_exists('rascal-app-job_service')
    docker.volume_exists('rascal-app-deploy-cache')

    result = run_rascal!('clean', '--all', '--volumes')

    expect(result.stdout).to include('Removing container for app-job_service', 'Removing volume rascal-app-deploy-cache')
  end

  it 'complains about --all together with an environment name' do
    result = run_rascal('clean', 'job', '--all')

    expect(result.exit_code).not_to eq 0
    expect(result.stderr).to include('Cannot give --all and an environment name!')
  end

end
