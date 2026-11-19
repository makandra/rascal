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

  it 'exits with 128 plus the signal number when the command was killed' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
    YAML
    allow(docker).to receive(:spawn).and_return(instance_double(Process::Status, success?: false, exitstatus: nil, termsig: 9))

    expect(run_rascal('run', 'job', '--', 'sleep', '100').exit_code).to eq 137
  end

end
