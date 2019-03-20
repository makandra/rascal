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
        if (definition = EnvironmentsDefinition.detect(config_location))
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
        else
          fail_with_error("Could not find an environment definition in current working directory.")
        end
      end
    end
  end
end
