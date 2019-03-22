module Rascal
  module CLI
    class Main < Thor
      def help(subcommand = false)
        if subcommand
          super
        else
          say
          say 'Usage:'
          say '  rascal <command> <args>'
          say 'For example:'
          say '  rascal shell 2.6'
          say
          super
          say 'For Further information about the commands, you can use "rascal help <command>".'
          say
        end
      end

      def self.exit_on_failure?
        # return non-zero exit code for failures
        true
      end

      def self.start(*)
        IOHelper.setup
        super
      end


      map "shell" => "_shell"
      desc 'shell ENVIRONMENT', 'Start a docker shell for the given environment'
      def _shell(environment_name = nil)
        Shell.new(self, options, environment_name).run
      end

      desc 'clean ENVIRONMENT', 'Stop and remove docker containers for the given environment'
      method_option :cache, type: :boolean, default: false
      def clean(environment_name = nil)
        Clean.new(self, options, environment_name).run
      end

      class_option :config_file, aliases: ['-c'], default: '.', required: true, banner: 'path to configuration file or directory containing it'
    end
  end
end
