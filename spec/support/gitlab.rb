require 'tmpdir'

# Helpers for specs of Rascal::Gitlab that read a .gitlab-ci.yml from a project directory.
module GitlabHelpers
  # Writes the config to a project directory called "repo", or another name, and returns its Jobs.
  def gitlab_jobs(yaml, project: 'repo')
    project_dir = @tmp_dir.join(project)
    project_dir.mkpath
    project_dir.join('.gitlab-ci.yml').write(yaml)
    Rascal::Gitlab::Jobs.new(project_dir.join('.gitlab-ci.yml'))
  end

  def project_dir(project = 'repo')
    @tmp_dir.join(project).to_s
  end

  def from_config(yaml, name)
    gitlab_jobs(yaml).environment(name)
  end
end

RSpec.configure do |config|
  config.define_derived_metadata(file_path: %r{/spec/rascal/gitlab/(jobs|environment_builder)_spec}) do |metadata|
    metadata[:gitlab_config] = true
  end

  config.include GitlabHelpers, gitlab_config: true

  config.around(:each, gitlab_config: true) do |example|
    Dir.mktmpdir do |dir|
      @tmp_dir = Pathname.new(dir)
      example.run
    end
  end
end
