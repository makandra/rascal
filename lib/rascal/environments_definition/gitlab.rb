module Rascal
  module EnvironmentsDefinition
    class Gitlab
      # Top-level keys that configure the pipeline as a whole instead of defining a job.
      # See https://docs.gitlab.com/ci/yaml/#global-keywords
      GLOBAL_KEYS = %w[default include stages variables workflow].freeze

      # Deprecated top-level keys that GitLab treats like the same keys in `default:`.
      GLOBAL_DEFAULT_KEYS = %w[image services cache before_script after_script].freeze

      # The keys of a job's combined config that rascal uses, besides variables.
      USED_KEYS = %w[image services before_shell after_shell volumes repo_dir].freeze

      # Settings for rascal that extend the `.rascal` block, outside of the CI config.
      LOCAL_CONFIG_FILE = '.rascal.yml'

      # GitLab's limit for nested `extends:`.
      MAX_EXTENDS_DEPTH = 10

      INPUTS_ADVICE = "`spec: inputs:` (`$[[ inputs.name ]]`), which rascal does not support. " \
                      "Set the value in the `.rascal` block."

      # GitLab's documented limit for nested `!reference` tags.
      MAX_REFERENCE_DEPTH = 10

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
      # priority. See #variable_layers. `problems` keep the job's environment from starting.
      Job = Struct.new(:key, :name, :config, :variable_layers, :problems, :warnings)


      def initialize(config_path)
        @file = GitlabFile.new(config_path)
        @info = @file.to_h
        @repo_dir = config_path.parent
        @base_name = @repo_dir.basename
        # Docker only allows some characters in names.
        @docker_name = @base_name.to_s.gsub(/[^a-zA-Z0-9_.-]/, '_').sub(/\A[^a-zA-Z0-9]/, 'x\\0')
        # A .rascal.yml next to .gitlab-ci.yml extends the .rascal block, for settings
        # that should not be part of the project's CI config.
        @rascal_config = deep_merge(hash_or_empty(@info['.rascal']), local_rascal_config(config_path))
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

      def local_rascal_config(config_path)
        path = config_path.parent.join(LOCAL_CONFIG_FILE)
        path.file? ? GitlabFile.new(path).to_h : {}
      end

      def jobs
        @jobs ||= @info.filter_map do |key, job_config|
          next if key.start_with?('.') || GLOBAL_KEYS.include?(key) || GLOBAL_DEFAULT_KEYS.include?(key)
          next unless job_config.is_a?(Hash)

          problems = []
          begin
            job_config = resolve_extends(key)
          rescue Error => e
            job_config = job_config.except('extends')
            # Only this job is affected, so keep the others usable.
            problems << e.message
          end
          rascal_job_config = hash_or_empty(@rascal_environment_config[key])
          # The .rascal block overrides the job, which overrides `default:`.
          # Variables are resolved separately, see #variable_layers.
          config = deep_merge(
            inherit_default(job_config),
            @rascal_config.except('variables'),
            rascal_job_config.except('variables'),
          )
          next if config['hide']

          # Like GitLab, resolve !reference tags after `extends:`. Only in the keys rascal uses,
          # so a reference into an unreadable include in `script:` does not get in the way.
          resolve = ->(value) { resolve_references(value, key, problems) }
          USED_KEYS.each { |used_key| config[used_key] = resolve.call(config[used_key]) if config.key?(used_key) }
          # References inside lists may resolve to lists, which GitLab flattens.
          %w[services before_shell after_shell].each do |list_key|
            next unless config.key?(list_key)

            value = config[list_key]
            config[list_key] = value.is_a?(Array) ? value.flatten : [value].compact
          end
          # A variable a reference would define might not be needed, or the .rascal block
          # might define it, so that is only worth a warning.
          warnings = []
          resolve_variables = ->(value) { resolve_references(value, key, warnings) }
          variable_layers = variable_layers(job_config, rascal_job_config, resolve_variables)

          Job.new(key, config.fetch('name', key).to_s, Config.new(config, key), variable_layers, problems, warnings)
        end
      end

      # Replaces !reference tags in `value` with what they point to, after `extends:`
      # (see Gitlab::Ci::Config::Yaml::Tags::Resolver). Adds a problem for each one that
      # cannot be resolved.
      def resolve_references(value, job_key, problems, in_progress = [])
        if GitlabFile.reference?(value)
          resolve_reference(value[GitlabFile::REFERENCE_KEY], job_key, problems, in_progress)
        elsif value.is_a?(Hash)
          value.to_h { |key, nested| [key, resolve_references(nested, job_key, problems, in_progress)] }
        elsif value.is_a?(Array)
          value.collect { |nested| resolve_references(nested, job_key, problems, in_progress) }
        else
          value
        end
      end

      def resolve_reference(location, job_key, problems, in_progress)
        unless location.is_a?(Array) && location.any? && location.none? { |key| key.is_a?(Hash) || key.is_a?(Array) }
          problems << "#{job_key}: !reference needs a list of keys, like `!reference [.template, services]`."
          return
        end

        location = location.collect(&:to_s)
        description = "!reference [#{location.join(', ')}]"
        if in_progress.include?(location)
          problems << "#{job_key}: #{description} references itself, directly or through other references."
        elsif in_progress.size >= MAX_REFERENCE_DEPTH
          problems << "#{job_key}: #{description} is nested too deeply."
        elsif (target = referenced_value(location)).nil?
          problems << "#{job_key}: #{description} could not be found. #{skipped_includes_hint}" \
                      "Set the config in the `.rascal` block (`.rascal: jobs: #{job_key}:`), or hide the job with `hide: true` there."
        else
          return resolve_references(target, job_key, problems, [*in_progress, location])
        end
        nil
      end

      # The value at a location like [.template, services], after `extends:`.
      def referenced_value(location)
        first, *rest = location
        rest.inject(extended_config(first)) { |current, key| current.is_a?(Hash) ? current[key] : nil }
      end

      def extended_config(key)
        @extended_configs ||= {}
        @extended_configs.fetch(key) do
          @extended_configs[key] = begin
            resolve_extends(key)
          rescue Error
            @info[key]
          end
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
          raise Error, "#{key}: unknown keys in `extends` (#{unknown.join(', ')}). #{skipped_includes_hint}" \
                       "Set the missing config in the `.rascal` block (`.rascal: jobs: #{ancestors.first || key}:`), " \
                       "or hide the job with `hide: true` there."
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
      def variable_layers(job_config, rascal_job_config, resolve)
        global_variables = hash_or_empty(resolve.call(@info['variables']))
        global_variables = global_variables.slice(*inherited_keys(job_config, 'variables', global_variables.keys))
        default_variables = hash_or_empty(resolve.call(hash_or_empty(@info['default'])['variables'])) # not supported by GitLab, kept for compatibility
        [
          global_variables.merge(default_variables).merge(hash_or_empty(resolve.call(job_config['variables']))),
          hash_or_empty(resolve.call(@rascal_config['variables'])),
          hash_or_empty(resolve.call(rascal_job_config['variables'])),
        ]
      end

      def build_environment(job)
        config = job.config
        docker_repo_dir = config.get('repo_dir', '/repo')
        full_name = "#{@docker_name}-#{job.name.gsub(/[^a-zA-Z0-9_.-]/, '_')}"
        shared_volumes = [build_repo_volume(docker_repo_dir), build_builds_volume(full_name)]
        variables = GitlabVariables.new(predefined_variables(job, docker_repo_dir), *job.variable_layers)
        problems = job.problems.dup
        warnings = job.warnings.dup
        Environment.new(full_name,
          name: job.name,
          image: image_name(job, variables, problems),
          entrypoint: entrypoint(job.config.get('image', nil)),
          volumes: [
            *shared_volumes,
            *build_volumes(full_name, config.get('volumes', {}))
          ],
          env_variables: resolve_variables(variables, problems, warnings),
          services: build_services(job, full_name, config.get('services', []), volumes: shared_volumes, variables: variables, problems: problems, warnings: warnings),
          before_shell: config.get('before_shell', []),
          after_shell: config.get('after_shell', []),
          working_dir: docker_repo_dir,
          ssh_agent: [true, 'true'].include?(config.get('ssh_agent', false)),
          services_timeout: config.get('services_timeout', Environment::DEFAULT_SERVICES_TIMEOUT),
          problems: problems.uniq,
          warnings: [*skipped_includes_warning, *warnings].uniq,
        )
      end

      # Returns the expanded variables. Records circular references as a problem,
      # and references to undefined variables as warnings.
      def resolve_variables(variables, problems, warnings, only: nil)
        resolved = variables.to_h
        undefined = variables.undefined_references
        undefined = undefined.slice(*only) if only
        warnings.concat(undefined_variable_warnings(undefined))
        resolved.slice(*(only || resolved.keys)).each do |name, value|
          warnings << "Variable #{name} uses #{INPUTS_ADVICE}" if value.include?('$[[')
        end
        resolved
      rescue Error => e
        problems << e.message
        {}
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
          # A job whose templates could not be resolved lacks its image as a consequence.
          return if job.problems.any?

          problems << "Job '#{job.key}' has no image. #{skipped_includes_hint}Set `image:` in the job, in `default:`, " \
                      "or in the `.rascal` block (`.rascal: jobs: #{job.key}: image:`)."
          return
        end

        if image.to_s.include?('$[[')
          problems << "The image of job '#{job.key}' (#{image}) uses #{INPUTS_ADVICE}"
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

      def entrypoint(image_config)
        entrypoint = image_config['entrypoint'] if image_config.is_a?(Hash)
        Array(entrypoint).collect(&:to_s) if entrypoint
      end

      def skipped_includes_warning
        return [] if @file.skipped_includes.empty?

        ["rascal cannot read these includes, so config from them is missing: #{skipped_includes_description}. " \
         "If the job needs services or variables from them, set them in the `.rascal` block."]
      end

      def skipped_includes_description
        @file.skipped_includes.collect do |entry|
          entry.is_a?(Hash) ? entry.slice('project', 'file', 'remote', 'template', 'component', 'local').collect { |k, v| "#{k}: #{Array(v).join(', ')}" }.join(', ') : entry.to_s
        end.join('; ')
      end

      # Explains config that may be missing because rascal cannot read some includes.
      def skipped_includes_hint
        return '' if @file.skipped_includes.empty?

        "It may come from an include rascal cannot read (#{skipped_includes_description}), since rascal only reads local includes. "
      end

      def undefined_variable_advice(name)
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

      def deep_merge(*hashes)
        hashes.inject { |result, hash| GitlabFile.deep_merge(hash_or_empty(result), hash_or_empty(hash)) }
      end

      def hash_or_empty(value)
        value.is_a?(Hash) ? value : {}
      end

      def build_services(job, name, services, volumes: [], variables:, problems:, warnings:)
        Array(services).collect do |service_config|
          # GitLab also allows services as a plain image name.
          service_config = { 'name' => service_config.to_s } unless service_config.is_a?(Hash)
          own_variables = hash_or_empty(service_config['variables'])
          service_variables = variables.merge(own_variables)
          raw_image = service_config['name'].to_s
          image = if raw_image.empty?
            problems << "A service of job '#{job.key}' has no image. Set `name:` for each service."
            nil
          elsif raw_image.include?('$[[')
            problems << "The service #{raw_image} of job '#{job.key}' uses #{INPUTS_ADVICE}"
            nil
          else
            expand_name(service_variables, raw_image, problems) do |undefined|
              "The service #{raw_image} of job '#{job.key}' uses the undefined variable #{undefined}. " \
              "#{undefined_variable_advice(undefined)}"
            end
          end
          aliases = service_aliases(service_config['alias'], image || raw_image)
          Service.new("#{name}_#{aliases.first}",
            aliases: aliases,
            image: image,
            volumes: volumes,
            env_variables: (service_env = resolve_variables(service_variables, problems, warnings, only: own_variables.keys.collect(&:to_s))),
            command: service_config['command'],
            healthcheck_port: (service_env['HEALTHCHECK_TCP_PORT'] if own_variables.key?('HEALTHCHECK_TCP_PORT')),
          )
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
