module Rascal
  module Gitlab
    # Builds the Environment for a resolved Job: Docker names, volumes, the image and services,
    # and the expanded variables. Collects what keeps the environment from starting as problems,
    # and what may make commands fail as warnings.
    class EnvironmentBuilder
      INPUTS_ADVICE = "`spec: inputs:` (`$[[ inputs.name ]]`), which rascal does not support. " \
                      "Set the value in the `.rascal` block."

      # `project_dir` is the directory of the .gitlab-ci.yml.
      def initialize(job, project_dir:)
        @job = job
        @config = job.config
        @project_dir = project_dir
      end

      def build
        @problems = @job.problems.dup
        @warnings = @job.warnings.dup
        repo_dir = @config.fetch('repo_dir', '/repo')
        shared_volumes = [Docker::Volume::Bind.new(@project_dir, repo_dir), Docker::Volume::Named.new("#{docker_name}-builds", '/builds')]
        variables = Variables.new(predefined_variables(repo_dir), *@job.variable_layers)
        Environment.new(docker_name,
          name: @job.name,
          image: image_name(variables),
          entrypoint: entrypoint,
          volumes: [*shared_volumes, *named_volumes],
          env_variables: resolve_variables(variables),
          services: services(variables, shared_volumes),
          before_shell: @config.fetch('before_shell', []),
          after_shell: @config.fetch('after_shell', []),
          working_dir: repo_dir,
          ssh_agent: [true, 'true'].include?(@config.fetch('ssh_agent', false)),
          services_timeout: services_timeout,
          problems: @problems.uniq,
          warnings: @warnings.uniq,
        )
      end

      private

      # Like `rascal-myapp-rspec` without the prefix. Docker only allows some characters in names.
      def docker_name
        project = @project_dir.basename.to_s.gsub(/[^a-zA-Z0-9_.-]/, '_').sub(/\A[^a-zA-Z0-9]/, 'x\\0')
        "#{project}-#{@job.name.gsub(/[^a-zA-Z0-9_.-]/, '_')}"
      end

      # A subset of the variables GitLab predefines for every job.
      # See https://docs.gitlab.com/ci/variables/predefined_variables/
      def predefined_variables(repo_dir)
        {
          'CI' => 'true',
          'GITLAB_CI' => 'true',
          'CI_JOB_NAME' => @job.key,
          'CI_PROJECT_NAME' => @project_dir.basename.to_s,
          'CI_PROJECT_DIR' => repo_dir,
          'CI_BUILDS_DIR' => '/builds',
        }
      end

      # Returns the expanded variables. Records circular references as a problem, and
      # references to undefined variables as warnings, only for the variables in `warn_for`
      # if given.
      def resolve_variables(variables, warn_for: nil)
        resolved = variables.to_h
        undefined = variables.undefined_references
        undefined = undefined.slice(*warn_for) if warn_for
        @warnings.concat(undefined_variable_warnings(undefined))
        resolved.slice(*(warn_for || resolved.keys)).each do |name, value|
          @warnings << "Variable #{name} uses #{INPUTS_ADVICE}" if value.include?('$[[')
        end
        resolved
      rescue Error => e
        @problems << e.message
        {}
      end

      # The expanded image name, or nil with the reason in the problems. Problems only matter
      # when the environment is started, so `rascal clean` can still clean an environment whose
      # image cannot be resolved.
      def image_name(variables)
        image = @config['image']
        image = image['name'] if image.is_a?(Hash)
        if image.nil? || image.to_s.empty?
          # A job whose templates could not be resolved lacks its image as a consequence.
          return if @job.problems.any?

          @problems << "Job '#{@job.key}' has no image. #{@job.missing_config_hint}Set `image:` in the job, in `default:`, " \
                       "or in the `.rascal` block (`.rascal: jobs: #{@job.key}: image:`)."
          return
        end

        if image.to_s.include?('$[[')
          @problems << "The image of job '#{@job.key}' (#{image}) uses #{INPUTS_ADVICE}"
          return
        end

        expand_name(variables, image) do |undefined|
          "The image of job '#{@job.key}' (#{image}) uses the undefined variable #{undefined}. #{undefined_variable_advice}"
        end
      end

      def entrypoint
        image = @config['image']
        entrypoint = image['entrypoint'] if image.is_a?(Hash)
        Array(entrypoint).collect(&:to_s) if entrypoint
      end

      # Expands a Docker image name, which must not reference undefined variables.
      def expand_name(variables, name, &error_message)
        undefined = []
        expanded = variables.expand(name) { |variable| undefined << variable }
        if undefined.any?
          @problems << error_message.call(undefined.first)
          nil
        else
          expanded
        end
      end

      def services_timeout
        value = @config.fetch('services_timeout', Environment::DEFAULT_SERVICES_TIMEOUT)
        Integer(value.to_s, 10).tap { |seconds| raise ArgumentError if seconds.negative? }
      rescue ArgumentError
        @problems << "services_timeout must be a number of seconds, not #{value.inspect}."
        Environment::DEFAULT_SERVICES_TIMEOUT
      end

      def named_volumes
        hash_or_empty(@config['volumes']).collect do |volume_name, path|
          Docker::Volume::Named.new("#{docker_name}-#{volume_name}", path)
        end
      end

      def services(variables, volumes)
        Array(@config.fetch('services', [])).collect do |service_config|
          # GitLab also allows services as a plain image name.
          service_config = { 'name' => service_config.to_s } unless service_config.is_a?(Hash)
          own_variables = Variables.null_as_empty(hash_or_empty(service_config['variables']))
          service_variables = variables.merge(own_variables)
          raw_image = service_config['name'].to_s
          image = service_image(raw_image, service_variables)
          aliases = service_aliases(service_config['alias'], image || raw_image)
          env_variables = resolve_variables(service_variables, warn_for: own_variables.keys.collect(&:to_s))
          Service.new("#{docker_name}_#{aliases.first}",
            aliases: aliases,
            image: image,
            volumes: volumes,
            env_variables: env_variables,
            command: service_config['command'],
            healthcheck_port: (env_variables['HEALTHCHECK_TCP_PORT'] if own_variables.key?('HEALTHCHECK_TCP_PORT')),
          )
        end
      end

      def service_image(raw_image, variables)
        if raw_image.empty?
          @problems << "A service of job '#{@job.key}' has no image. Set `name:` for each service."
          nil
        elsif raw_image.include?('$[[')
          @problems << "The service #{raw_image} of job '#{@job.key}' uses #{INPUTS_ADVICE}"
          nil
        else
          expand_name(variables, raw_image) do |undefined|
            "The service #{raw_image} of job '#{@job.key}' uses the undefined variable #{undefined}. #{undefined_variable_advice}"
          end
        end
      end

      # GitLab allows several aliases, separated by commas or spaces. Without an alias, a
      # service gets the host names GitLab derives from its image:
      # `registry.example.com:5000/group/postgres:15` becomes `registry.example.com-group-postgres`
      # and `registry.example.com__group__postgres`.
      def service_aliases(alias_config, image)
        aliases = alias_config.to_s.split(/[\s,]+/).reject(&:empty?)
        return aliases if aliases.any?

        name = image.sub(/@.*\z/, '')           # digest
          .sub(%r{:[^/:]*\z}, '')               # tag
          .sub(%r{\A([^/]+):\d+(?=/)}, '\\1')    # registry port
          .gsub(/[^a-zA-Z0-9_.\/-]/, '')         # anything Docker does not allow in names, like an unresolved $
        name = 'service' if name.empty?
        [name.tr('/', '-'), name.gsub('/', '__')].uniq
      end

      def undefined_variable_advice
        "It is probably set by GitLab or in the project's CI/CD settings, which rascal cannot see. " \
        "Define it for rascal under `variables:` in the `.rascal` block."
      end

      def undefined_variable_warnings(undefined_references)
        undefined_references.collect do |name, undefined|
          "Variable #{name} references #{undefined.join(', ')}, which #{undefined.size == 1 ? 'is' : 'are'} undefined " \
          "and expanded to an empty string. If the job needs #{undefined.size == 1 ? 'it' : 'them'}, " \
          "define #{undefined.size == 1 ? 'it' : 'them'} under `variables:` in the `.rascal` block."
        end
      end

      def hash_or_empty(value)
        value.is_a?(Hash) ? value : {}
      end
    end
  end
end
