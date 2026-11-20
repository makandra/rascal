require 'pathname'

module Rascal
  module CLI
    class Base
      include IOHelper

      def initialize(options)
        @options = options
      end

      private

      # Changes to the environment for a single command, from --env, --unset-env and --ssh-agent.
      def command_overrides
        env = Array(@options[:env]).to_h do |assignment|
          name, value = assignment.split('=', 2)
          fail_with_error('Use --env NAME=VALUE, like --env RAILS_ENV=test.') unless value && variable_name?(name)
          [name, value]
        end
        unset_env = Array(@options[:unset_env]).each do |name|
          fail_with_error('Use --unset-env NAME, like --unset-env CI.') unless variable_name?(name)
        end
        { env: env, unset_env: unset_env, ssh_agent: @options[:ssh_agent] }
      end

      def variable_name?(name)
        name.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/)
      end

      def config_location
        Pathname.new(@options[:config_file]).expand_path
      end

      def fail_with_error(message)
        raise Thor::Error, message
      end

      def find_environment(environment_name)
        jobs = project_jobs
        jobs.environment(environment_name) or begin
          available_environments = jobs.names.join(', ')
          if environment_name
            fail_with_error("Unknown job #{environment_name}. Jobs: #{available_environments}.")
          else
            fail_with_error("Missing job. Jobs: #{available_environments}.")
          end
        end
      end

      # The environment name, or :all with --all.
      def name_or_all(environment_name)
        return environment_name unless @options[:all]

        fail_with_error('Give either a job or --all.') if environment_name
        :all
      end

      def each_environment(name, &block)
        return enum_for(:each_environment, name) unless block_given?

        if name == :all
          jobs = project_jobs
          jobs.names.each do |environment_name|
            yield jobs.environment(environment_name)
          end
        else
          yield find_environment(name)
        end
      end

      def project_jobs
        Gitlab::Jobs.find(config_location) or
          fail_with_error("Could not find a .gitlab-ci.yml in #{config_location}. Run rascal in your project's root directory, " \
                          "or point to the file with --config-file.")
      end
    end
  end
end
