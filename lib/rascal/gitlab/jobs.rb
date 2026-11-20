module Rascal
  module Gitlab
    # A job, resolved like GitLab does, with rascal's settings applied.
    # `variable_layers` are its variable definitions, from the lowest to the highest priority
    # (see Jobs#variable_layers). `problems` keep its environment from starting, `warnings`
    # may make commands fail. `missing_config_hint` starts a message about config the job
    # lacks, which may come from includes rascal cannot read.
    Job = Struct.new(:key, :name, :config, :variable_layers, :problems, :warnings, :missing_config_hint)

    # The jobs of a .gitlab-ci.yml, resolved like GitLab does: `extends:`, `default:`,
    # `inherit:` and `!reference`. rascal's settings from the `.rascal` block and a `.rascal.yml`
    # override each job's config, and add variables on top of the job's.
    class Jobs
      # Top-level keys that configure the pipeline as a whole instead of defining a job.
      # See https://docs.gitlab.com/ci/yaml/#global-keywords
      GLOBAL_KEYS = %w[default include stages variables workflow].freeze

      # Deprecated top-level keys that GitLab treats like the same keys in `default:`.
      GLOBAL_DEFAULT_KEYS = %w[image services cache before_script after_script].freeze

      # The keys of a job's config in which rascal resolves `!reference` tags. Others, like
      # `script:`, may reference includes rascal cannot read, and rascal does not need them.
      KEYS_WITH_REFERENCES = %w[image services before_shell after_shell volumes repo_dir].freeze

      # Settings for rascal that extend the `.rascal` block, outside of the CI config.
      LOCAL_CONFIG_FILE = '.rascal.yml'

      # GitLab's limit for nested `extends:`.
      MAX_EXTENDS_DEPTH = 10

      # GitLab's documented limit for nested `!reference` tags.
      MAX_REFERENCE_DEPTH = 10

      # The jobs of the .gitlab-ci.yml at `path`, or in the directory `path`. Nil if there is none.
      def self.find(path)
        path = path.join('.gitlab-ci.yml') if path.directory?
        new(path) if path.file?
      end

      def initialize(config_path)
        @project_dir = config_path.parent
        @file = ConfigFile.new(config_path)
        @ci_config = @file.to_h
        # A .rascal.yml next to .gitlab-ci.yml extends the .rascal block, for settings
        # that should not be part of the project's CI config.
        @rascal_config = deep_merge(hash_or_empty(@ci_config['.rascal']), local_rascal_config)
        @rascal_job_configs = hash_or_empty(@rascal_config.delete('jobs'))
      end

      # The names of the jobs rascal can use as environments, including ones whose environment
      # cannot start.
      def names
        jobs.collect(&:name).sort
      end

      # The Job with the given name, or nil.
      def job(name)
        jobs.detect { |job| job.name == name }
      end

      # The Environment of the job with the given name, or nil.
      def environment(name)
        if (job = job(name))
          EnvironmentBuilder.new(job, project_dir: @project_dir).build
        end
      end

      private

      def skipped_includes_warning
        return if @file.skipped_includes.empty?

        "rascal cannot read these includes, so config from them is missing: #{@file.skipped_includes_description}. " \
        "If the job needs services or variables from them, set them in the `.rascal` block."
      end

      # Explains that missing config may come from an include rascal cannot read.
      def skipped_includes_hint
        return '' if @file.skipped_includes.empty?

        "It may come from an include rascal cannot read (#{@file.skipped_includes_description}), since rascal only reads local includes. "
      end

      def local_rascal_config
        path = @project_dir.join(LOCAL_CONFIG_FILE)
        path.file? ? ConfigFile.new(path).to_h : {}
      end

      def jobs
        @jobs ||= @ci_config.filter_map do |key, job_config|
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
          rascal_job_config = hash_or_empty(@rascal_job_configs[key])
          # The .rascal block overrides the job, which overrides `default:`.
          # Variables are resolved separately, see #variable_layers.
          rascal_overlays = [@rascal_config.except('variables'), rascal_job_config.except('variables')]
          config = deep_merge(image_as_hash(inherit_default(job_config), rascal_overlays), *rascal_overlays)
          next if config['hide']

          # Like GitLab, resolve !reference tags after `extends:`. Only in the keys rascal uses,
          # so a reference into an unreadable include in `script:` does not get in the way.
          resolve = ->(value) { resolve_references(value, key, problems) }
          KEYS_WITH_REFERENCES.each { |config_key| config[config_key] = resolve.call(config[config_key]) if config.key?(config_key) }
          # References inside lists may resolve to lists, which GitLab flattens.
          %w[services before_shell after_shell].each do |list_key|
            next unless config.key?(list_key)

            value = config[list_key]
            config[list_key] = value.is_a?(Array) ? value.flatten : [value].compact
          end
          # A variable a reference would define might not be needed, or the .rascal block
          # might define it, so that is only worth a warning.
          warnings = [*skipped_includes_warning]
          resolve_variables = ->(value) { resolve_references(value, key, warnings) }
          variable_layers = variable_layers(job_config, rascal_job_config, resolve_variables)

          Job.new(key, config.fetch('name', key).to_s, config, variable_layers, problems, warnings, skipped_includes_hint)
        end
      end

      # GitLab allows `image: name` and `image: { name: ..., entrypoint: ... }`. If rascal's settings
      # give only part of the long form, like `image: { entrypoint: [''] }` to skip an entrypoint,
      # turn the job's short form into the long one, so they merge instead of losing the name.
      def image_as_hash(config, overlays)
        image = config['image']
        return config unless image.is_a?(String) && overlays.any? { |overlay| overlay['image'].is_a?(Hash) }

        config.merge('image' => { 'name' => image })
      end

      # Replaces !reference tags in `value` with what they point to, after `extends:`
      # (see Gitlab::Ci::Config::Yaml::Tags::Resolver). Adds a problem for each one that
      # cannot be resolved.
      def resolve_references(value, job_key, problems, in_progress = [])
        if ConfigFile.reference?(value)
          resolve_reference(value[ConfigFile::REFERENCE_KEY], job_key, problems, in_progress)
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
            @ci_config[key]
          end
        end
      end

      # Merges the job's `extends:` templates into it, like GitLab does
      # (see Gitlab::Ci::Config::Extendable::Entry).
      def resolve_extends(key, ancestors = [])
        config = @ci_config[key]
        return config unless config.is_a?(Hash) && config.key?('extends')

        if ancestors.include?(key)
          raise Error, "#{key}: circular dependency detected in `extends`"
        elsif ancestors.size > MAX_EXTENDS_DEPTH
          raise Error, "#{key}: nesting too deep in `extends`"
        end

        bases = Array(config['extends']).collect(&:to_s)
        if (unknown = bases.reject { |base| @ci_config.key?(base) }).any?
          raise Error, "#{key}: unknown keys in `extends` (#{unknown.join(', ')}). #{skipped_includes_hint}" \
                       "Set the missing config in the `.rascal` block (`.rascal: jobs: #{ancestors.first || key}:`), " \
                       "or hide the job with `hide: true` there."
        elsif (invalid = bases.reject { |base| @ci_config[base].is_a?(Hash) }).any?
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
        @default_config ||= @ci_config.slice(*GLOBAL_DEFAULT_KEYS).merge(hash_or_empty(@ci_config['default']))
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
      # variables, like `RUBYOPT: $RUBYOPT -W:deprecated`, or remove one with `CI: null`.
      # In GitLab's own variables, null means an empty string.
      def variable_layers(job_config, rascal_job_config, resolve)
        global_variables = hash_or_empty(resolve.call(@ci_config['variables']))
        global_variables = global_variables.slice(*inherited_keys(job_config, 'variables', global_variables.keys))
        default_variables = hash_or_empty(resolve.call(hash_or_empty(@ci_config['default'])['variables'])) # not supported by GitLab, kept for compatibility
        [
          Variables.null_as_empty(global_variables.merge(default_variables).merge(hash_or_empty(resolve.call(job_config['variables'])))),
          hash_or_empty(resolve.call(@rascal_config['variables'])),
          hash_or_empty(resolve.call(rascal_job_config['variables'])),
        ]
      end

      def deep_merge(*hashes)
        hashes.inject { |result, hash| ConfigFile.deep_merge(hash_or_empty(result), hash_or_empty(hash)) }
      end

      def hash_or_empty(value)
        value.is_a?(Hash) ? value : {}
      end
    end
  end
end
