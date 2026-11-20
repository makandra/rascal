describe 'rascal environments' do

  it 'lists environment names one per line' do
    gitlab_ci_config(<<~YAML)
      job-1:
        image: job-image:latest
      job-2:
        image: job-image:latest
    YAML

    expect(run_rascal!('environments').stdout).to eq "job-1\njob-2\n"
  end

  it 'complains when there is no .gitlab-ci.yml' do
    result = run_rascal('environments')

    expect(result.exit_code).not_to eq 0
    expect(result.stderr).to include("Could not find a .gitlab-ci.yml in #{project_dir}. Run rascal in your project's root directory, or point to the file with --config-file.")
  end
end
