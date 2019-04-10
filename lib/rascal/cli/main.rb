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
        handle_error do
          Shell.new(self, options, environment_name).run
        end
      end

      desc 'clean ENVIRONMENT', 'Stop and remove docker containers for the given environment'
      method_option :volumes, type: :boolean, default: false, desc: 'Remove (cache) volumes'
      method_option :all, type: :boolean, default: false, desc: 'Clean all environments'
      def clean(environment_name = nil)
        handle_error do
          Clean.new(self, options, environment_name).run
        end
      end

      desc 'update ENVIRONMENT', 'Update all docker images'
      method_option :all, type: :boolean, default: false, desc: 'update all available environments'
      def update(environment_name = nil)
        handle_error do
          Update.new(self, options, environment_name).run
        end
      end

      class_option :config_file, aliases: ['-c'], default: '.', required: true, desc: 'path to configuration file or directory containing it'

      private

      def handle_error
        yield
      rescue Rascal::Error => e
        raise Thor::Error, e.message
      end
    end
  end
end
