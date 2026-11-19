describe 'rascal environments' do

  it 'lists environment names one per line, honoring renamed and hidden jobs' do
    gitlab_ci_config(<<~YAML)
      .rascal:
        jobs:
          job-2:
            name: renamed-job
          hidden-job:
            hide: true
      job-1:
        image: job-image:latest
      job-2:
        image: job-image:latest
      hidden-job:
        image: job-image:latest
    YAML

    expect(run_rascal!('environments').stdout).to eq "job-1\nrenamed-job\n"
  end

  it 'complains when there is no .gitlab-ci.yml' do
    result = run_rascal('environments')

    expect(result.exit_code).not_to eq 0
    expect(result.stderr).to include('Could not find an environment definition')
  end

  it 'complains about an unknown environment, listing the available ones' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
    YAML

    result = run_rascal('run', 'nope', '--', 'rake')

    expect(result.exit_code).not_to eq 0
    expect(result.stderr).to include('Unknown environment nope. Available: job.')
  end

end
