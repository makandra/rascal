# `rascal help` should teach basic usage on its own, for people and agents.
describe 'rascal help' do

  around do |example|
    # Thor shortens command summaries to the terminal width.
    original_columns = ENV['THOR_COLUMNS']
    ENV['THOR_COLUMNS'] = '80'
    example.run
  ensure
    ENV['THOR_COLUMNS'] = original_columns
  end

  it 'shows the typical use, the commands without cutting their summaries, and where the README is' do
    result = run_rascal!('help')

    expect(result.stdout).to include(
      "rascal run rspec -- bundle install",
      "rascal clean --all --volumes",
      "rascal status JOB shows what rascal made of the job",
      "  #{Rascal::CLI::Main::README_PATH}\n",
      "  https://github.com/makandra/rascal#readme\n",
    )
    expect(File).to exist(Rascal::CLI::Main::README_PATH)
    command_lines = result.stdout[/^Commands:\n(.*?)\n\n/m, 1].lines
    expect(command_lines.size).to eq 7
    expect(command_lines).to all(satisfy { |line| !line.include?('...') })
  end

  it 'explains each command with examples that stay on one line' do
    run = run_rascal!('help', 'run')
    status = run_rascal!('help', 'status')

    expect(run.stdout).to include("    rascal run rspec --unset-env CI --ssh-agent -- bundle update rack --conservative\n")
    expect(status.stdout).to include('Without a job, shows all.')
  end

end
