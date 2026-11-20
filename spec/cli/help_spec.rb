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
      "rascal does not run the job's before_script or script.",
      "rascal clean --all --volumes",
      "  #{Rascal::CLI::Main::README_PATH}\n",
    )
    # Seven commands, including help.
    command_lines = result.stdout[/^Commands:\n(.*?)\n\n/m, 1].lines
    expect(command_lines.size).to eq 7
    expect(command_lines).to all(satisfy { |line| !line.include?('...') })
  end

  it 'refers to a README that is packaged into the gem' do
    gem_root = File.expand_path('../..', __dir__)
    files = Dir.chdir(gem_root) { Gem::Specification.load('rascal.gemspec').files }

    expect(Rascal::CLI::Main::README_PATH).to eq File.join(gem_root, 'README.md')
    expect(files).to include('README.md')
  end

  it 'fits its own text into 80 columns, apart from option lists' do
    outputs = ['help', 'run', 'shell', 'status', 'environments', 'clean', 'update'].collect do |command|
      command == 'help' ? run_rascal!('help').stdout : run_rascal!('help', command).stdout
    end

    lines = outputs.join.lines.reject { |line| line.match?(/\A\s*(-|\[)/) }
    expect(lines.select { |line| line.chomp.length > 80 }).to eq []
  end

  it 'shows the help of a command for --help or -h, but leaves a -h of the command to run alone' do
    gitlab_ci_config(<<~YAML)
      rspec:
        image: job-image:latest
    YAML

    expect(run_rascal!('run', '--help').stdout).to include('Usage:', 'rascal run rspec -- bash -c')
    expect(run_rascal!('shell', 'rspec', '-h').stdout).to include('Opens bash in the environment')
    expect(run_rascal!('run', 'rspec', '--help').stdout).to include('Usage:')
    expect(run_rascal!('run', '--env', 'X=1', '-h').stdout).to include('Usage:')
    run_rascal!('run', 'rspec', 'ls', '-h')
    run_rascal!('run', 'rspec', '--', 'grep', '--help')
    expect(docker.commands.grep(/container run/).collect { |command| command[/\nls -h\n|\ngrep --help\n/] }).to eq ["\nls -h\n", "\ngrep --help\n"]
  end

  it 'explains each command with examples that stay on one line' do
    run = run_rascal!('help', 'run')
    status = run_rascal!('help', 'status')

    expect(run.stdout).to include("    rascal run rspec -- bash -c 'bin/rails db:migrate && bundle exec rspec'\n")
    expect(status.stdout).to include('Without a job, shows all.')
  end

end
