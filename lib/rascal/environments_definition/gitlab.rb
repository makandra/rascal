require 'yaml'

module Rascal
  module EnvironmentsDefinition
    class Gitlab
      # Top-level keys that configure the pipeline as a whole instead of defining a job.
      # See https://docs.gitlab.com/ci/yaml/#global-keywords
      GLOBAL_KEYS = %w[default include stages variables workflow].freeze

      # Deprecated top-level keys that GitLab treats like the same keys in `default:`.
      GLOBAL_DEFAULT_KEYS = %w[image services cache before_script after_script].freeze

      # GitLab's limit for nested `extends:`.
      MAX_EXTENDS_DEPTH = 10

      class << self
        def detect(path)
          if path.directory?
            path = path.join('.gitlab-ci.yml')
          end
          if path.file?
            new(path)
          end
        end
      end

      class Config
        def initialize(config, prefix)
          @config = config
          @prefix = prefix
        end

        def get(key, *default)
          if @config.has_key?(key)
            @config[key]
          elsif default.size > 0
            default.first
          else
            raise Error.new("missing config for '#{@prefix}.#{key}'")
          end
        end
      end

      # `variable_layers` are the job's variable definitions, from the lowest to the highest
      # priority. See #variable_layers.
      Job = Struct.new(:key, :name, :config, :variable_layers)


      def initialize(config_path)
        @info = stringify_keys(hash_or_empty(parse_definition(config_path.read)))
        @repo_dir = config_path.parent
        @base_name = @repo_dir.basename
        @rascal_config = hash_or_empty(@info['.rascal']).dup
        @rascal_environment_config = hash_or_empty(@rascal_config.delete('jobs'))
      end

      def environment(name)
        if (job = jobs.detect { |j| j.name == name })
          build_environment(job)
        end
      end

      def available_environment_names
        jobs.collect(&:name).sort
      end

      private

      def parse_definition(yaml)
        if Psych::VERSION >= '3.1'
          YAML.safe_load(yaml, aliases: true)
        else
          YAML.safe_load(yaml, [], [], true)
        end
      end

      def jobs
        @jobs ||= @info.filter_map do |key, job_config|
          next if key.start_with?('.') || GLOBAL_KEYS.include?(key) || GLOBAL_DEFAULT_KEYS.include?(key)
          next unless job_config.is_a?(Hash)

          job_config = resolve_extends(key)
          rascal_job_config = hash_or_empty(@rascal_environment_config[key])
          # The .rascal block overrides the job, which overrides `default:`.
          # Variables are resolved separately, see #variable_layers.
          config = Config.new(deep_merge(
            inherit_default(job_config),
            @rascal_config.except('variables'),
            rascal_job_config.except('variables'),
          ), key)
          next if config.get('hide', false)

          Job.new(key, config.get('name', key), config, variable_layers(job_config, rascal_job_config))
        end
      end

      # Merges the job's `extends:` templates into it, like GitLab does
      # (see Gitlab::Ci::Config::Extendable::Entry).
      def resolve_extends(key, ancestors = [])
        config = @info[key]
        return config unless config.is_a?(Hash) && config.key?('extends')

        if ancestors.include?(key)
          raise Error, "#{key}: circular dependency detected in `extends`"
        elsif ancestors.size > MAX_EXTENDS_DEPTH
          raise Error, "#{key}: nesting too deep in `extends`"
        end

        bases = Array(config['extends']).collect(&:to_s)
        if (unknown = bases.reject { |base| @info.key?(base) }).any?
          raise Error, "#{key}: unknown keys in `extends` (#{unknown.join(', ')})"
        elsif (invalid = bases.reject { |base| @info[base].is_a?(Hash) }).any?
          raise Error, "#{key}: invalid base hashes in `extends` (#{invalid.join(', ')})"
        end

        merged = bases.inject({}) do |result, base|
          deep_merge(result, resolve_extends(base, [*ancestors, key]))
        end
        deep_merge(merged, config)
      end

      # Like GitLab, a key the job sets replaces the same key in `default:` as a whole
      # (see Gitlab::Ci::Config::Entry::Processable#overwrite_entry), and `inherit: default:`
      # limits what a job takes from `default:`.
      def inherit_default(job_config)
        inherited = default_config.slice(*inherited_keys(job_config, 'default', default_config.keys))
        inherited.merge(job_config)
      end

      def default_config
        @default_config ||= @info.slice(*GLOBAL_DEFAULT_KEYS).merge(hash_or_empty(@info['default']))
      end

      # The keys a job inherits, according to its `inherit:` setting for `kind`
      # (`default` or `variables`), which may be true, false or a list of keys.
      def inherited_keys(job_config, kind, all_keys)
        case (setting = hash_or_empty(job_config['inherit'])[kind])
        when false then []
        when Array then all_keys & setting.collect(&:to_s)
        else all_keys
        end
      end

      # Variable definitions from the lowest to the highest priority. A variable that
      # references its own name gets its value from a lower layer.
      #
      # GitLab merges global and job variables by name before expanding them (see
      # Gitlab::Ci::Variables::Helpers.merge_variables), so they form one layer.
      # The .rascal block adds its own layers on top, so it can extend a job's
      # variables, like `RUBYOPT: $RUBYOPT -W:deprecated`.
      def variable_layers(job_config, rascal_job_config)
        global_variables = hash_or_empty(@info['variables'])
        global_variables = global_variables.slice(*inherited_keys(job_config, 'variables', global_variables.keys))
        [
          global_variables
            .merge(hash_or_empty(hash_or_empty(@info['default'])['variables'])) # not supported by GitLab, kept for compatibility
            .merge(hash_or_empty(job_config['variables'])),
          hash_or_empty(@rascal_config['variables']),
          hash_or_empty(rascal_job_config['variables']),
        ]
      end

      def build_environment(job)
        config = job.config
        docker_repo_dir = config.get('repo_dir', '/repo')
        full_name = "#{@base_name}-#{job.name}"
        shared_volumes = [build_repo_volume(docker_repo_dir), build_builds_volume(full_name)]
        variables = GitlabVariables.new(predefined_variables(job, docker_repo_dir), *job.variable_layers)
        problems = []
        Environment.new(full_name,
          name: job.name,
          image: image_name(job, variables, problems),
          volumes: [
            *shared_volumes,
            *build_volumes(full_name, config.get('volumes', {}))
          ],
          env_variables: variables.to_h,
          services: build_services(job, full_name, config.get('services', []), volumes: shared_volumes, variables: variables, problems: problems),
          before_shell: config.get('before_shell', []),
          after_shell: config.get('after_shell', []),
          working_dir: docker_repo_dir,
          problems: problems,
          warnings: undefined_variable_warnings(variables),
        )
      end

      # A subset of the variables GitLab predefines for every job.
      # See https://docs.gitlab.com/ci/variables/predefined_variables/
      def predefined_variables(job, docker_repo_dir)
        {
          'CI' => 'true',
          'GITLAB_CI' => 'true',
          'CI_JOB_NAME' => job.key,
          'CI_PROJECT_NAME' => @base_name.to_s,
          'CI_PROJECT_DIR' => docker_repo_dir,
          'CI_BUILDS_DIR' => '/builds',
        }
      end

      # Returns the expanded image name, or nil after adding the reason to `problems`.
      # Problems only matter when the environment is started, so `rascal clean` can still
      # clean an environment whose image cannot be resolved.
      def image_name(job, variables, problems)
        image = job.config.get('image', nil)
        image = image['name'] if image.is_a?(Hash)
        if image.nil? || image.to_s.empty?
          problems << "Job '#{job.key}' has no image. Set `image:` in the job, in `default:`, " \
                      "or in the `.rascal` block (`.rascal: jobs: #{job.key}: image:`)."
          return
        end

        expand_name(variables, image, problems) do |undefined|
          "The image of job '#{job.key}' (#{image}) uses the undefined variable #{undefined}. " \
          "#{undefined_variable_advice(undefined)}"
        end
      end

      # Expands a Docker image name, which must not reference undefined variables.
      def expand_name(variables, name, problems, &error_message)
        undefined = []
        expanded = variables.expand(name) { |variable| undefined << variable }
        if undefined.any?
          problems << error_message.call(undefined.first)
          nil
        else
          expanded
        end
      end

      def undefined_variable_advice(name)
        "It is probably set by GitLab or in the project's CI/CD settings, which rascal cannot see. " \
        "Define it for rascal under `variables:` in the `.rascal` block."
      end

      def undefined_variable_warnings(variables)
        variables.undefined_references.collect do |name, undefined|
          "Variable #{name} references #{undefined.join(', ')}, which #{undefined.size == 1 ? 'is' : 'are'} undefined " \
          "and expanded to an empty string. If the job needs #{undefined.size == 1 ? 'it' : 'them'}, " \
          "define #{undefined.size == 1 ? 'it' : 'them'} under `variables:` in the `.rascal` block."
        end
      end

      def deep_merge(hash1, hash2, *other)
        result = {}
        if hash1.is_a?(Hash) && hash2.is_a?(Hash)
          hash1.each do |key1, value1|
            if hash2.has_key?(key1)
              result[key1] = deep_merge(value1, hash2[key1])
            else
              result[key1] = value1
            end
          end
          hash2.each do |key2, value2|
            result[key2] ||= value2
          end
        else
          result = hash2
        end
        if other.any?
          deep_merge(result, *other)
        else
          result
        end
      end

      def hash_or_empty(value)
        value.is_a?(Hash) ? value : {}
      end

      # YAML turns keys like `2.6:` into numbers. GitLab treats all keys as strings.
      def stringify_keys(value)
        case value
        when Hash then value.to_h { |key, nested| [key.to_s, stringify_keys(nested)] }
        when Array then value.collect { |nested| stringify_keys(nested) }
        else value
        end
      end

      def build_services(job, name, services, volumes: [], variables:, problems:)
        Array(services).collect do |service_config|
          # GitLab also allows services as a plain image name.
          service_config = { 'name' => service_config.to_s } unless service_config.is_a?(Hash)
          service_variables = variables.merge(hash_or_empty(service_config['variables']))
          image = expand_name(service_variables, service_config['name'].to_s, problems) do |undefined|
            "The service #{service_config['name']} of job '#{job.key}' uses the undefined variable #{undefined}. " \
            "#{undefined_variable_advice(undefined)}"
          end
          aliases = service_config['alias'] ? [service_config['alias'].to_s] : default_service_aliases(image.to_s)
          Service.new("#{name}_#{aliases.first}",
            aliases: aliases,
            image: image,
            volumes: volumes,
            env_variables: service_variables.to_h,
            command: service_config['command'],
          )
        end
      end

      # The host names GitLab derives from a service's image when it has no alias:
      # `registry.example.com/group/postgres:15` becomes `registry.example.com-group-postgres`
      # and `registry.example.com__group__postgres`.
      def default_service_aliases(image)
        name = image.sub(/@.*\z/, '').sub(%r{:[^/:]*\z}, '')
        [name.tr('/', '-'), name.gsub('/', '__')].uniq
      end

      def build_repo_volume(docker_repo_dir)
        Docker::Volume::Bind.new(@repo_dir, docker_repo_dir)
      end

      def build_builds_volume(name)
        Docker::Volume::Named.new("#{name}-builds", '/builds')
      end

      def build_volumes(name, volume_config)
        hash_or_empty(volume_config).collect do |volume_name, docker_path|
          Docker::Volume::Named.new("#{name}-#{volume_name}", docker_path)
        end
      end
    end
  end
end
