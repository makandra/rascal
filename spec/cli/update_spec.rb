describe 'rascal update' do

  it 'pulls the images of the job and its services' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
        services:
          - name: service-image:stable
            alias: service
    YAML

    result = run_rascal!('update', 'job')

    expect(result.stdout).to include('Updating image service-image:stable', 'Updating image job-image:latest')
    expect(docker.commands).to include('docker pull service-image:stable', 'docker pull job-image:latest')
  end

  it "explains why it cannot update a job's images" do
    gitlab_ci_config(<<~YAML)
      deploy:
        image: $CI_REGISTRY_IMAGE/deploy:latest
    YAML

    result = run_rascal('update', 'deploy')

    expect(result.exit_code).not_to eq 0
    expect(result.stderr).to include("The image of job 'deploy'")
    expect(docker.commands).to eq []
  end

  it 'pulls each image once with --all, and skips environments it cannot resolve' do
    gitlab_ci_config(<<~YAML)
      job-1:
        image: job-image:latest
      job-2:
        image: job-image:latest
      deploy:
        image: $CI_REGISTRY_IMAGE/deploy:latest
    YAML

    result = run_rascal!('update', '--all')

    expect(docker.commands.count('docker pull job-image:latest')).to eq 1
    expect(result.stderr).to include("Skipping deploy: The image of job 'deploy'")
  end

end
