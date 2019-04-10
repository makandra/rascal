require 'pathname'

module Rascal
  module CLI
    class Base
      def initialize(thor, options)
        @thor = thor
        @options = options
      end

      private

      def config_location
        Pathname.new(@options[:config_file]).expand_path
      end

      def fail_with_error(message)
        raise Thor::Error, message
      end

      def find_environment(environment_name)
        definition = environment_definition
        if (environment = definition.environment(environment_name))
          return environment
        else
          available_environments = definition.available_environment_names.join(', ')
          if environment_name
            fail_with_error("Unknown environment #{environment_name}. Available: #{available_environments}.")
          else
            fail_with_error("Missing environment. Available: #{available_environments}.")
          end
        end
      end

      def each_environment(name, &block)
        return enum_for(:each_environment) unless block_given?

        if name == :all
          definition = environment_definition
          definition.available_environment_names.each do |environment_name|
            yield definition.environment(environment_name)
          end
        else
          yield find_environment(name)
        end
      end

      def environment_definition
        if (definition = EnvironmentsDefinition.detect(config_location))
          definition
        else
          fail_with_error("Could not find an environment definition in current working directory.")
          nil
        end
      end
    end
  end
end
