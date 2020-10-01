require 'yaml'

module Rascal
  module EnvironmentsDefinition
    class Gitlab
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


      def initialize(config_path)
        @info = parse_definition(config_path.read)
        @repo_dir = config_path.parent
        @base_name = @repo_dir.basename
        @rascal_config = @info.fetch('.rascal', {})
        @rascal_environment_config = @rascal_config.delete('jobs') || {}
      end

      def environment(name)
        environments.detect do |e|
          e.name == name
        end
      end

      def available_environment_names
        environments.collect(&:name).sort
      end

      private

      def parse_definition(yaml)
        if Psych::VERSION >= '3.1'
          YAML.safe_load(yaml, aliases: true)
        else
          YAML.safe_load(yaml, [], [], true)
        end
      end

      def environments
        @environments ||= begin
          @info.collect do |key, environment_config|
            config = Config.new(deep_merge(environment_config, @rascal_config, @rascal_environment_config[key] || {}), key)
            docker_repo_dir = config.get('repo_dir', '/repo')
            unless key.start_with?('.') || config.get('hide', false)
              name = config.get('name', key)
              full_name = "#{@base_name}-#{name}"
              shared_volumes = [build_repo_volume(docker_repo_dir), build_builds_volume(full_name)]
              env_variables = (config.get('variables', {}))
              Environment.new(full_name,
                name: name,
                image: config.get('image'),
                volumes: [
                  *shared_volumes,
                  *build_volumes(full_name, config.get('volumes', {}))
                ],
                env_variables: env_variables,
                services: build_services(full_name, config.get('services', []), volumes: shared_volumes, env_variables: env_variables),
                before_shell: config.get('before_shell', []),
                after_shell: config.get('after_shell', []),
                working_dir: docker_repo_dir,
              )
            end
          end.compact
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

      def build_services(name, services, volumes: [], env_variables: {})
        services.collect do |service_config|
          service_alias = service_config['alias']
          Service.new("#{name}_#{service_alias}",
            alias_name: service_config['alias'],
            image: service_config['name'],
            volumes: volumes,
            env_variables: env_variables,
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

