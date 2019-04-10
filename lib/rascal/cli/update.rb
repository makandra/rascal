require 'rascal'

module Rascal
  module CLI
    class Update < Base
      def initialize(thor, options, environment_name)
        @environment_name = if options[:all]
          fail_with_error('Cannot give --all and an environment name!') if environment_name
          :all
        else
          environment_name
        end
        super(thor, options)
      end

      def run
        images = []
        each_environment(@environment_name) do |environment|
          images += environment.update(skip: images)
        end
      end
    end
  end
end
