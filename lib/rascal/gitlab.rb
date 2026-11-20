module Rascal
  # Turns a project's .gitlab-ci.yml into environments:
  #
  # - ConfigFile reads the YAML with its local includes.
  # - Jobs resolves each job like GitLab does (`extends:`, `default:`, `!reference`), and adds
  #   rascal's settings from the `.rascal` block and `.rascal.yml`.
  # - EnvironmentBuilder turns a resolved Job into an Environment with Docker names, volumes and
  #   services, expanding variables with Variables.
  module Gitlab
    autoload :ConfigFile,         'rascal/gitlab/config_file'
    autoload :EnvironmentBuilder, 'rascal/gitlab/environment_builder'
    autoload :Jobs,               'rascal/gitlab/jobs'
    autoload :Variables,          'rascal/gitlab/variables'
  end
end
