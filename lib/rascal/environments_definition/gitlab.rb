require 'yaml'

module Rascal
  module EnvironmentsDefinition
    class Gitlab
      # Top-level keys that configure the pipeline as a whole instead of defining a job.
      # See https://docs.gitlab.com/ci/yaml/#global-keywords
      GLOBAL_KEYS = %w[default include stages variables workflow].freeze

      # Deprecated top-level keys that GitLab treats like the same keys in `default:`.
      GLOBAL_DEFAULT_KEYS = %w[image services cache before_script after_script].freeze

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

      Job = Struct.new(:key, :name, :config)


      def initialize(config_path)
        @info = hash_or_empty(parse_definition(config_path.read))
        @repo_dir = config_path.parent
        @base_name = @repo_dir.basename
        @rascal_config = @info.fetch('.rascal', {}).dup
        @rascal_environment_config = @rascal_config.delete('jobs') || {}
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
          key = key.to_s
          next if key.start_with?('.') || GLOBAL_KEYS.include?(key) || GLOBAL_DEFAULT_KEYS.include?(key)
          next unless job_config.is_a?(Hash)

          # The .rascal block overrides the job, which overrides `default:`.
          config = Config.new(deep_merge(inherit_default(job_config), @rascal_config, @rascal_environment_config[key] || {}), key)
          next if config.get('hide', false)

          Job.new(key, config.get('name', key), config)
        end
      end

      # Like GitLab, a key the job sets replaces the same key in `default:` as a whole
      # (see Gitlab::Ci::Config::Entry::Processable#overwrite_entry).
      # Variables are merged instead, since rascal has always merged them.
      def inherit_default(job_config)
        default_config.merge(job_config) do |key, default_value, job_value|
          key == 'variables' ? deep_merge(default_value, job_value) : job_value
        end
      end

      def default_config
        @default_config ||= @info.slice(*GLOBAL_DEFAULT_KEYS).merge(hash_or_empty(@info['default']))
      end

      def build_environment(job)
        config = job.config
        docker_repo_dir = config.get('repo_dir', '/repo')
        full_name = "#{@base_name}-#{job.name}"
        shared_volumes = [build_repo_volume(docker_repo_dir), build_builds_volume(full_name)]
        variables = GitlabVariables.new(
          predefined_variables(job, docker_repo_dir),
          hash_or_empty(@info['variables']),
          hash_or_empty(config.get('variables', {})),
        )
        Environment.new(full_name,
          name: job.name,
          image: image_name(job, variables),
          volumes: [
            *shared_volumes,
            *build_volumes(full_name, config.get('volumes', {}))
          ],
          env_variables: variables.to_h,
          services: build_services(job, full_name, config.get('services', []), volumes: shared_volumes, variables: variables),
          before_shell: config.get('before_shell', []),
          after_shell: config.get('after_shell', []),
          working_dir: docker_repo_dir,
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

      def image_name(job, variables)
        image = job.config.get('image', nil)
        image = image['name'] if image.is_a?(Hash)
        if image.nil? || image.to_s.empty?
          raise Error, "Job '#{job.key}' has no image. Set `image:` in the job, in `default:`, or in the `.rascal` block."
        end

        expand_name(variables, image) do |undefined|
          "The image of job '#{job.key}' (#{image}) uses the undefined variable #{undefined}. " \
          "Define #{undefined} under `variables:`, or set the image in the `.rascal` block."
        end
      end

      # Expands a docker image name, which must not reference undefined variables.
      def expand_name(variables, name, &error_message)
        variables.expand(name) do |undefined|
          raise Error, error_message.call(undefined)
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

      def build_services(job, name, services, volumes: [], variables:)
        services.collect do |service_config|
          service_alias = service_config['alias']
          service_variables = variables.merge(hash_or_empty(service_config['variables']))
          image = expand_name(service_variables, service_config['name']) do |undefined|
            "The service #{service_config['name']} of job '#{job.key}' uses the undefined variable #{undefined}. " \
            "Define #{undefined} under `variables:`, or set the services in the `.rascal` block."
          end
          Service.new("#{name}_#{service_alias}",
            alias_name: service_alias,
            image: image,
            volumes: volumes,
            env_variables: service_variables.to_h,
            command: service_config['command'],
          )
        end
      end

      def build_repo_volume(docker_repo_dir)
        Docker::Volume::Bind.new(@repo_dir, docker_repo_dir)
      end

      def build_builds_volume(name)
        Docker::Volume::Named.new("#{name}-builds", '/builds')
      end

      def build_volumes(name, volume_config)
        volume_config.collect do |volume_name, docker_path|
          Docker::Volume::Named.new("#{name}-#{volume_name}", docker_path)
        end
      end
    end
  end
end
