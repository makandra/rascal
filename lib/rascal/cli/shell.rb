require 'rascal'

module Rascal
  module CLI
    class Shell < Base
      def initialize(thor, options, environment_name)
        @environment_name = environment_name
        super(thor, options)
      end

      def run
        find_environment(@environment_name)&.run_shell
      end
    end
  end
end
