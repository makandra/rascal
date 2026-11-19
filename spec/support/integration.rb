require 'open3'
require 'rbconfig'
require 'securerandom'
require 'tmpdir'

# Helpers for integration specs, which run the real rascal executable against a real
# Docker daemon. Each example gets a project directory with a unique name, so its
# containers, networks and volumes cannot collide with real rascal environments.
module IntegrationHelpers
  RASCAL = File.expand_path('../../exe/rascal', __dir__)
  LIB = File.expand_path('../../lib', __dir__)

  # Small images, so a first run only pulls a few megabytes.
  JOB_IMAGE = 'bash:5.2'
  REDIS_IMAGE = 'redis:7-alpine'

  Result = Struct.new(:stdout, :stderr, :status) do
    def success?
      status.success?
    end

    def exit_code
      status.exitstatus
    end
  end

  class << self
    def ensure_docker!
      return if @docker_checked

      _output, status = Open3.capture2e('docker', 'info')
      unless status.success?
        raise 'Integration specs need a running Docker daemon, but `docker info` failed. ' \
              'Start Docker, or run only the fast specs with `bundle exec rspec --tag ~integration`.'
      end
      @docker_checked = true
    end
  end

  attr_reader :project_dir

  # The name rascal derives its Docker resource names from.
  def project_name
    File.basename(project_dir)
  end

  def create_project(gitlab_ci_yml)
    @project_dir = File.join(Dir.tmpdir, "rascal-it-#{SecureRandom.hex(4)}")
    Dir.mkdir(@project_dir)
    File.write(File.join(@project_dir, '.gitlab-ci.yml'), gitlab_ci_yml)
  end

  def rascal(*args)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{LIB}", RASCAL, *args, chdir: project_dir, stdin_data: '')
    Result.new(stdout, stderr, status)
  end

  def rascal!(*args)
    result = rascal(*args)
    unless result.success?
      raise "rascal #{args.join(' ')} failed with exit code #{result.exit_code}:\n#{result.stdout}\n#{result.stderr}"
    end
    result
  end

  def docker(*args)
    output, _status = Open3.capture2e('docker', *args)
    output
  end

  # Names of all containers, networks and volumes belonging to this project.
  def docker_resources
    filter = "name=rascal-#{project_name}"
    [
      *docker('ps', '--all', '--filter', filter, '--format', '{{.Names}}').lines,
      *docker('network', 'ls', '--filter', filter, '--format', '{{.Name}}').lines,
      *docker('volume', 'ls', '--filter', filter, '--format', '{{.Name}}').lines,
    ].map(&:strip).reject(&:empty?)
  end

  # Removes the project directory and everything rascal created in Docker for it.
  # Warns instead of failing, so a broken cleanup does not hide the actual test result.
  def remove_project
    return unless project_dir && File.directory?(project_dir)

    result = rascal('clean', '--all', '--volumes')
    warn "Integration spec cleanup: `rascal clean` failed:\n#{result.stderr}" unless result.success?
    remove_leftover_docker_resources
    # Containers may have created files the current user cannot delete.
    docker('run', '--rm', '-v', "#{project_dir}:/project", JOB_IMAGE, 'sh', '-c', 'rm -rf /project/* /project/.[!.]*')
    FileUtils.rm_rf(project_dir)
    warn "Integration spec cleanup: could not remove #{project_dir}" if File.exist?(project_dir)
  end

  def remove_leftover_docker_resources
    leftovers = docker_resources
    return if leftovers.empty?

    warn "Integration spec cleanup: removing leftovers #{leftovers.join(', ')}"
    docker('rm', '--force', '--volumes', *leftovers)
    docker('network', 'rm', *leftovers)
    docker('volume', 'rm', *leftovers)
  end
end

RSpec.configure do |config|
  config.define_derived_metadata(file_path: %r{/spec/integration/}) do |metadata|
    metadata[:integration] = true
  end

  config.include IntegrationHelpers, integration: true

  config.before(:context, integration: true) do
    IntegrationHelpers.ensure_docker!
  end

  config.after(:each, integration: true) do
    remove_project
  end
end
