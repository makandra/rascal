require 'rascal'

module Rascal
  module CLI
    class Clean < Base
      def initialize(thor, options, environment_name)
        @environment_name = environment_name
        super(thor, options)
      end

      def run
        find_environment(@environment_name)&.clean(clean_volumes: @options[:cache])
      end
    end
  end
end
