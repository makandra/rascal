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
        @rascal_config = @info.fetch('.rascal', {})
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
        YAML.safe_load(yaml, [], [], true)
      end

      def environments
        @environments ||= begin
          @info.collect do |key, environment_config|
            config = Config.new(deep_merge(environment_config, @rascal_config), key)
            docker_repo_dir = config.get('repo_dir')
            unless key.start_with?('.')
              Environment.new(key,
                image: config.get('image'),
                env_variables: (config.get('variables', {})),
                services: build_services(key, config.get('services', [])),
                volumes: [build_repo_volume(docker_repo_dir), *build_volumes(key, config.get('volumes', {}))],
                before_shell: config.get('before_shell', []),
                working_dir: docker_repo_dir,
              )
            end
          end.compact
        end
      end

      def deep_merge(hash1, hash2)
        if hash1.is_a?(Hash) && hash2.is_a?(Hash)
          result = {}
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
          result
        else
          hash2
        end
      end

      def build_services(name, services)
        services.collect do |service_config|
          service_alias = service_config['alias']
          Service.new("#{name}_#{service_alias}",
            alias_name: service_config['alias'],
            image: service_config['name'],
          )
        end
      end

      def build_repo_volume(docker_repo_dir)
        Docker::Volume::Bind.new(@repo_dir, docker_repo_dir)
      end

      def build_volumes(name, volume_config)
        volume_config.collect do |volume_name, docker_path|
          Docker::Volume::Named.new("#{name}-#{volume_name}", docker_path)
        end
      end
    end
  end
end

