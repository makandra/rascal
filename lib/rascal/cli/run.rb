require 'rascal'

module Rascal
  module CLI
    class Run < Base
      def initialize(thor, options, environment_name, command)
        @environment_name = environment_name
        @command = command
        super(thor, options)
      end

      def run
        if (environment = find_environment(@environment_name))
          fail_with_error('Missing command. Example: rascal run job -- bundle exec rake') if @command.empty?
          status = environment.run_command(*@command)
          exit(exit_code_for(status))
        end
      end

      private

      # A command killed by a signal has no exit status. Report it the way a
      # shell would, so callers still see a non-zero status.
      def exit_code_for(status)
        status.exitstatus || (status.termsig ? 128 + status.termsig : 1)
      end
    end
  end
end
