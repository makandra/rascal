require 'json'

# What `rascal status` shows. The real Docker states are covered by spec/integration.
describe 'rascal status' do

  before do
    gitlab_ci_config(<<~YAML)
      .rascal:
        before_shell:
          - bundle check
      job:
        image: job-image:latest
        variables:
          FOO: bar
        services:
          - name: postgres:16
            alias: db
          - name: redis:7
            alias: redis
          - name: memcached:1
            alias: memcached
      deploy:
        image: $CI_REGISTRY_IMAGE/deploy:latest
        services:
          - name: deploy-db:1
            alias: db
    YAML
    docker.image_exists('job-image:latest', entrypoint: ['/docker-entrypoint.sh'])
    docker.image_exists('postgres:16', exposed_ports: ['5432/tcp'])
    docker.container_exists('rascal-app-job_db', running: true, started_at: Time.utc(2026, 11, 20, 10))
    docker.container_exists('rascal-app-job_redis', exit_code: 1)
  end

  it "shows the job's config and the state of its services, with the command to see their logs" do
    result = run_rascal!('status', 'job')

    expect(result.stdout).to include(<<~TEXT)
      job
        Image:      job-image:latest
        Entrypoint: ["/docker-entrypoint.sh"] (from the image)
        Network:    rascal-app-job
        Services:
          db: postgres:16, running since 2026-11-20T10:00:00Z
            Waits for port 5432
            Logs: docker logs rascal-app-job_db
          redis: redis:7 (not downloaded), exited with exit code 1
            Logs: docker logs rascal-app-job_redis
          memcached: memcached:1 (not downloaded), not created, the next command starts it
    TEXT
    expect(result.stdout).to include("    FOO=bar\n", "    CI=true\n", "  before_shell:\n    bundle check\n")
  end

  it "shows why Docker could not start a service, and the job's command containers" do
    docker.container_exists('rascal-app-job_db', error: 'exec: "/nonexistent": no such file or directory')
    docker.container_exists('rascal-app-job-run-0123abcd', running: true)
    docker.container_exists('rascal-app-job-run-tests_db', running: true)

    result = run_rascal!('status', 'job')

    expect(result.stdout).to include(
      "    db: postgres:16, created, but never started\n" \
      "      Error: exec: \"/nonexistent\": no such file or directory\n" \
      "      Waits for port 5432\n" \
      "    redis:"
    )
    expect(result.stdout).to include("  Command containers: rascal-app-job-run-0123abcd\n")
  end

  it 'shows why a job cannot start, without suggesting that the next command starts it' do
    result = run_rascal!('status', 'deploy')

    expect(result.stdout).to start_with(
      "deploy\n" \
      "  Image:      (none)\n" \
      "  Problem:    The image of job 'deploy' ($CI_REGISTRY_IMAGE/deploy:latest) uses the undefined variable CI_REGISTRY_IMAGE."
    )
    expect(result.stdout).to include("    db: deploy-db:1 (not downloaded), not created\n")
    expect(result.stdout).not_to include('next command')
  end

  it 'shows all environments without a name, and prints JSON with --json' do
    all = JSON.parse(run_rascal!('status', '--json').stdout)
    job = JSON.parse(run_rascal!('status', 'job', '--json').stdout)

    expect(all.collect { |status| status['name'] }).to contain_exactly('job', 'deploy')
    expect(job).to include('name' => 'job', 'image' => 'job-image:latest', 'image_present' => true)
    expect(job['services'].first).to include('aliases' => ['db'], 'state' => 'running', 'container' => 'rascal-app-job_db')
    expect(job['services'][1]).to include('state' => 'exited', 'exit_code' => 1)
  end

  it "shows the image's own entrypoint next to one rascal's settings replace it with" do
    File.write(File.join(project_dir, '.rascal.yml'), "jobs:\n  job:\n    image:\n      entrypoint: ['']\n")

    result = run_rascal!('status', 'job')

    expect(result.stdout).to include(%(  Entrypoint: [""] (instead of the image's ["/docker-entrypoint.sh"])\n))
  end

  it 'starts and downloads nothing' do
    run_rascal!('status')

    expect(docker.commands).not_to include(match(/pull|create|start|network create|container run/))
  end

end
