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
          say '  rascal run rspec -- bundle exec rspec spec/models/user_spec.rb'
          say
          super
          say 'For more about a command, run "rascal help <command>". The README explains setup and troubleshooting:'
          say '  https://github.com/makandra/rascal#readme'
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
      desc 'shell ENVIRONMENT', 'Open an interactive bash in an environment'
      def _shell(environment_name = nil)
        handle_error do
          Shell.new(self, options, environment_name).run
        end
      end

      desc 'environments', 'List the jobs you can use as environments'
      def environments
        handle_error do
          Environments.new(self, options).run
        end
      end

      # Thor::Actions already defines #run, hence the mapping.
      map 'run' => '_run'
      stop_on_unknown_option! :_run
      desc 'run ENVIRONMENT -- COMMAND', 'Run a command in an environment'
      long_desc <<~TEXT
        Runs a command in the environment of a CI job, without a terminal, and exits with its status.
        Everything after -- is passed on as arguments. For shell syntax, use bash -c:

        rascal run rspec -- bash -c 'bin/rails db:migrate && bundle exec rspec'
      TEXT
      def _run(environment_name = nil, *command)
        handle_error do
          command = command.drop(1) if command.first == '--'
          Run.new(self, options, environment_name, command).run
        end
      end

      desc 'clean ENVIRONMENT | --all', 'Remove an environment'
      method_option :volumes, type: :boolean, default: false, desc: 'Also remove volumes, like caches'
      method_option :all, type: :boolean, default: false, desc: 'Clean all environments'
      def clean(environment_name = nil)
        handle_error do
          Clean.new(self, options, environment_name).run
        end
      end

      desc 'update ENVIRONMENT | --all', "Pull an environment's latest images"
      method_option :all, type: :boolean, default: false, desc: 'Update all environments'
      def update(environment_name = nil)
        handle_error do
          Update.new(self, options, environment_name).run
        end
      end

      class_option :config_file, aliases: ['-c'], default: '.', required: true, desc: 'The .gitlab-ci.yml to use, or its directory'

      private

      def handle_error
        yield
      rescue Rascal::Error => e
        raise Thor::Error, e.message
      end
    end
  end
end
