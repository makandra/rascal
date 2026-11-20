# `rascal shell` needs a terminal, so these specs check the docker command it calls.
# Starting the environment is covered by starting_an_environment_spec.rb.
describe 'rascal shell' do

  it 'runs bash in the job image, interactively with a TTY' do
    gitlab_ci_config(<<~YAML)
      .rascal:
        before_shell:
          - bundle check
      job:
        image: job-image:latest
        variables:
          FOO: bar
    YAML

    run_rascal!('shell', 'job')

    expect(docker.commands.grep(/container run/).last).to match(
      %r{\Adocker container run --rm --name rascal-app-job-run-\h{8} -a STDOUT -a STDERR -a STDIN --interactive --tty -w /repo -v .*/app:/repo -v rascal-app-job-builds:/builds -e CI=true .* -e FOO=bar --network deadbeef job-image:latest bash -c bundle check\nbash\n}
    )
  end

  it 'changes variables for this shell only, like rascal run' do
    gitlab_ci_config(<<~YAML)
      job:
        image: job-image:latest
    YAML

    run_rascal!('shell', 'job', '--env', 'FOO=bar', '--unset-env', 'CI')

    shell_command = docker.commands.grep(/container run/).last
    expect(shell_command).to include('-e FOO=bar')
    expect(shell_command).not_to include('-e CI=')
  end

end
