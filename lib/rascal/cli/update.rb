require 'rascal'

module Rascal
  module CLI
    class Update < Base
      def initialize(options, environment_name)
        super(options)
        @environment_name = name_or_all(environment_name)
      end

      def run
        images = []
        each_environment(@environment_name) do |environment|
          if @environment_name == :all && environment.problems.any?
            # Typically a job that does not run tests, like a deploy job using $CI_REGISTRY_IMAGE.
            info("Skipping #{environment.name}: #{environment.problems.join(' ')}")
            next
          end
          images += environment.update(skip: images)
        end
      end
    end
  end
end
