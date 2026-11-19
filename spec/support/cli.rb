require 'rascal/cli'
require 'stringio'
require 'tmpdir'

# Helpers for specs that run rascal's command line in the same process,
# with a mocked Docker (see DockerMockInterface).
#
# The project directory is always called "app", so Docker resources get
# predictable names like "rascal-app-job".
module CLIHelpers
  Result = Struct.new(:stdout, :stderr, :exit_code) do
    def success?
      exit_code == 0
    end
  end

  def docker
    Rascal::Docker.interface
  end

  def gitlab_ci_config(yaml)
    File.write(File.join(project_dir, '.gitlab-ci.yml'), yaml)
  end

  def project_dir
    @project_dir ||= File.join(@tmp_dir, 'app').tap { |dir| Dir.mkdir(dir) }
  end

  # Runs rascal with the given arguments in the project directory, and returns its output
  # and exit code.
  def run_rascal(*args)
    stdout = StringIO.new
    stderr = StringIO.new
    original_stdout, original_stderr = $stdout, $stderr
    $stdout, $stderr = stdout, stderr
    exit_code = begin
      # The option goes right after the command, since `run` passes everything after `--` on.
      Rascal::CLI::Main.start([args.first, '--config-file', project_dir, *args.drop(1)])
      0
    rescue SystemExit => e
      e.status
    ensure
      $stdout, $stderr = original_stdout, original_stderr
      Rascal::IOHelper.setup
    end
    Result.new(stdout.string, stderr.string, exit_code)
  end

  def run_rascal!(*args)
    run_rascal(*args).tap do |result|
      raise "rascal #{args.join(' ')} failed with exit code #{result.exit_code}:\n#{result.stdout}\n#{result.stderr}" unless result.success?
    end
  end
end

RSpec.configure do |config|
  config.define_derived_metadata(file_path: %r{/spec/cli/}) do |metadata|
    metadata[:cli] = true
  end

  config.include CLIHelpers, cli: true

  config.around(:each, cli: true) do |example|
    Rascal::Docker.interface = DockerMockInterface.new
    Dir.mktmpdir do |tmp_dir|
      @tmp_dir = tmp_dir
      example.run
    end
  ensure
    Rascal::Docker.interface = nil
  end
end
