require 'rascal'

module Rascal
  module CLI
    class Shell < Base
      def initialize(options, environment_name)
        @environment_name = environment_name
        super(options)
      end

      def run
        find_environment(@environment_name).run_shell(**command_overrides)
      end
    end
  end
end
