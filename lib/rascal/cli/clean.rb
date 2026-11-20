require 'rascal'

module Rascal
  module CLI
    class Clean < Base
      def initialize(options, environment_name)
        super(options)
        @environment_name = name_or_all(environment_name)
      end

      def run
        each_environment(@environment_name) do |environment|
          environment.clean(clean_volumes: @options[:volumes])
        end
      end
    end
  end
end
