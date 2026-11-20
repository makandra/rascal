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

    expect(result.stderr).not_to include('Stopping')
    expect(result.stderr).to include('Removing container for app-job_service', 'Removing network rascal-app-job')
    expect(docker.commands).to include(match(/container rm --volumes/), match(/network rm/))
  end

  it "removes containers left over from commands that were killed, but not those of another job whose name starts the same" do
    docker.container_exists('rascal-app-job-run-0123abcd')
    docker.container_exists('rascal-app-job-run-tests_db')

    result = run_rascal!('clean', 'job')

    expect(result.stderr).to include('Removing 1 leftover command container for app-job')
    expect(docker.commands).to include("docker container rm --force --volumes #{docker.container_id('rascal-app-job-run-0123abcd')}")
    expect(docker.commands.join("\n")).not_to include(docker.container_id('rascal-app-job-run-tests_db'))
  end

  it 'keeps volumes unless asked to remove them' do
    docker.volume_exists('rascal-app-job-cache')

    expect(run_rascal!('clean', 'job').stderr).not_to include('Removing volume')
    expect(run_rascal!('clean', 'job', '--volumes').stderr).to include('Removing volume rascal-app-job-cache')
  end

  it 'cleans all environments, including those whose image cannot be resolved' do
    docker.container_exists('rascal-app-job_service')
    docker.volume_exists('rascal-app-deploy-cache')

    result = run_rascal!('clean', '--all', '--volumes')

    expect(result.stderr).to include('Removing container for app-job_service', 'Removing volume rascal-app-deploy-cache')
  end

  it 'complains about --all together with an environment name' do
    result = run_rascal('clean', 'job', '--all')

    expect(result.exit_code).not_to eq 0
    expect(result.stderr).to include('Give either a job or --all.')
  end

end
