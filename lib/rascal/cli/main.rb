require 'rascal'

module Rascal
  module CLI
    class Main < Thor
      # Options that change a single `run` or `shell`, like for updating dependencies.
      def self.command_environment_options
        method_option :env, type: :string, repeatable: true, banner: 'NAME=VALUE',
          desc: 'Set a variable in the container, for this command only. Repeat for more.'
        method_option :unset_env, type: :string, repeatable: true, banner: 'NAME',
          desc: 'Remove a variable from the container, like CI, for this command only. Repeat for more.'
        method_option :ssh_agent, type: :boolean,
          desc: 'Give the container access to your SSH agent, for this command only. --no-ssh-agent keeps it away, even if the config enables it.'
      end
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
          say 'For more about a command, run "rascal help <command>". rascal --version prints the version.'
          say 'The README explains setup and troubleshooting:'
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
      long_desc <<~TEXT
        Opens bash in the environment of a CI job, like for a Rails console or a debugger.
        Needs a terminal. Without one, use rascal run.
      TEXT
      command_environment_options
      def _shell(environment_name = nil)
        handle_error do
          Shell.new(options, environment_name).run
        end
      end

      desc 'environments', 'List the jobs you can use as environments'
      def environments
        handle_error do
          Environments.new(options).run
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

        Options go before --. Variables and the SSH agent can change for a single command:

        rascal run rspec --unset-env CI --ssh-agent -- bundle update rack --conservative
      TEXT
      command_environment_options
      def _run(environment_name = nil, *command)
        handle_error do
          run_options, command = split_run_arguments(command)
          Run.new(run_options, environment_name, command).run
        end
      end

      desc 'clean ENVIRONMENT | --all', 'Remove an environment'
      long_desc <<~TEXT
        Stops and removes the environment's services with their data, like databases, its network
        and leftover command containers. Named volumes, like caches, stay unless you pass --volumes.
        Files in the project stay. The next command starts the services fresh.
      TEXT
      method_option :volumes, type: :boolean, desc: 'Also remove volumes, like caches'
      method_option :all, type: :boolean, desc: 'Clean all environments'
      def clean(environment_name = nil)
        handle_error do
          Clean.new(options, environment_name).run
        end
      end

      desc 'update ENVIRONMENT | --all', "Pull an environment's latest images"
      long_desc <<~TEXT
        Pulls the latest images of the job and its services. Services that already run keep their
        old image until you run rascal clean.
      TEXT
      method_option :all, type: :boolean, desc: 'Update all environments'
      def update(environment_name = nil)
        handle_error do
          Update.new(options, environment_name).run
        end
      end

      # Thor's own command in newer versions, of no use here.
      if Thor.method_defined?(:tree)
        desc 'tree', 'Print a tree of all available commands', hide: true
        def tree
          super
        end
      end

      class_option :config_file, aliases: ['-c'], default: '.', required: true, desc: 'The .gitlab-ci.yml to use, or its directory'

      private

      # Thor stops parsing options at the environment name of `run`, so the command can have
      # options of its own. Options between the environment name and `--`, like
      # `rascal run rspec -c path -- cmd`, are parsed here. A command without a leading `--`,
      # like `rascal run rspec git checkout -- file`, is taken as it is.
      def split_run_arguments(arguments)
        return [options, arguments.drop(1)] if arguments.first == '--'
        return [options, arguments] unless arguments.first&.start_with?('-')

        separator = arguments.index('--') or
          raise Thor::Error, "Put -- between rascal's options and the command, like: rascal run rspec #{arguments.first} ... -- COMMAND"
        known_options = self.class.class_options.merge(self.class.commands['_run'].options)
        parser = Thor::Options.new(known_options)
        defaults = Thor::Options.new(known_options).parse([])
        given = parser.parse(arguments.take(separator))
        parser.check_unknown!
        if parser.remaining.any?
          raise Thor::Error, "Unexpected #{parser.remaining.join(' ')} before --. Usage: rascal run [OPTIONS] ENVIRONMENT -- COMMAND"
        end

        merged = options.to_h
        given.each do |name, value|
          next if defaults[name] == value

          # Repeatable options, like --env, may come before and after the environment name.
          merged[name] = value.is_a?(Array) ? Array(merged[name]) + value : value
        end
        [Thor::CoreExt::HashWithIndifferentAccess.new(merged), arguments.drop(separator + 1)]
      end

      def handle_error
        yield
      rescue Rascal::Error => e
        raise Thor::Error, e.message
      end
    end
  end
end
