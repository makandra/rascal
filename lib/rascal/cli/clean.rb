require 'rascal'

module Rascal
  module CLI
    class Clean < Base
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
        each_environment(@environment_name) do |environment|
          environment.clean(clean_volumes: @options[:volumes])
        end
      end
    end
  end
end
