require 'rascal'

module Rascal
  module CLI
    class Main < Thor
      # A command's description, indented like the other parts of `rascal help COMMAND`. It is
      # not wrapped, so examples stay on one line.
      def self.indented(text)
        text.gsub(/^(?=.)/, '  ')
      end

      # Options that change a single `run` or `shell`, like for updating dependencies.
      def self.command_environment_options
        method_option :env, type: :string, repeatable: true, banner: 'NAME=VALUE',
          desc: 'Set a variable in the container, for this command only. Repeat for more.'
        method_option :unset_env, type: :string, repeatable: true, banner: 'NAME',
          desc: 'Remove a variable from the container, like CI, for this command only. Repeat for more.'
        method_option :ssh_agent, type: :boolean,
          desc: 'Give the container access to your SSH agent, for this command only. --no-ssh-agent keeps it away, even if the config enables it.'
      end
      # The README that comes with this version of rascal, packaged into the gem.
      README_PATH = File.expand_path('../../../README.md', __dir__)

      def help(subcommand = false)
        return super if subcommand

        say <<~TEXT

          rascal runs the environment of a GitLab CI job locally in Docker: the job's image with
          your project mounted at /repo, and the job's services, like a database. Run it in the
          project's root directory, where .gitlab-ci.yml is.

          Typical use, with a job called rspec:
            rascal environments                                # list the jobs
            rascal status rspec                                # what rascal made of a job, starts nothing
            rascal run rspec -- bundle install                 # set up; the first run downloads images
            rascal run rspec -- bundle exec rspec spec/models  # work
            rascal shell rspec                                 # interactive bash, needs a terminal
            rascal clean --all --volumes                       # tear down

        TEXT
        super
        say <<~TEXT
          Good to know:
            - Each command runs in a new container. Services keep running between commands, and
              files in the project and in volumes stay.
            - Options go before --. rascal run rspec --env NAME=VALUE --unset-env CI --ssh-agent -- ...
              changes the container for this one command.
            - Lasting settings go into a .rascal.yml next to .gitlab-ci.yml.
            - If something does not work, rascal status JOB shows what rascal made of the job, and
              how its services run.

          For more about a command, run "rascal help COMMAND". rascal --version prints the version.
          The README explains setup, configuration and troubleshooting:
        TEXT
        say "  #{README_PATH}"
        say
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
      desc 'shell JOB', "Open bash in a job's environment"
      long_desc indented(<<~TEXT), wrap: false
          Opens bash in the environment of a CI job, like for a Rails console or a debugger,
          with before_shell and after_shell around it. Needs a terminal. Without one, like as
          an AI agent, use rascal run.

            rascal shell rspec
      TEXT
      command_environment_options
      def _shell(environment_name = nil)
        handle_error do
          Shell.new(options, environment_name).run
        end
      end

      desc 'status [JOB]', "Show a job's environment, starts nothing"
      long_desc indented(<<~TEXT), wrap: false
          Shows what rascal made of the CI config: the image, services, variables, before_shell
          and after_shell, and any problems. Also shows what exists in Docker: whether images are
          downloaded, the state of each service with the command to see its logs, the network,
          volumes and running commands. Starts and downloads nothing. Without a job, shows all.

            rascal status rspec
            rascal status --json
      TEXT
      method_option :json, type: :boolean, desc: 'Print JSON, for scripts and agents'
      def status(environment_name = nil)
        handle_error do
          Status.new(options, environment_name).run
        end
      end

      desc 'environments', 'List the jobs you can use'
      long_desc indented(<<~TEXT), wrap: false
          Lists the jobs of .gitlab-ci.yml, one per line, including ones rascal cannot start,
          like deploy jobs. Pick the one that runs the tests, usually rspec or test.
      TEXT
      def environments
        handle_error do
          Environments.new(options).run
        end
      end

      # Thor::Actions already defines #run, hence the mapping.
      map 'run' => '_run'
      stop_on_unknown_option! :_run
      desc 'run JOB -- COMMAND', "Run a command in a job's environment"
      long_desc indented(<<~TEXT), wrap: false
          Runs a command in the environment of a CI job, without a terminal, and exits with the
          command's status. Starts the job's services first, and waits until they accept
          connections. stdout is the command's output, rascal's own messages go to stderr.

          Everything after -- is passed on as arguments. For shell syntax, use bash -c:

            rascal run rspec -- bundle exec rspec spec/models/user_spec.rb
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

      desc 'clean JOB | --all', "Remove a job's services and network"
      long_desc indented(<<~TEXT), wrap: false
          Stops and removes the environment's services with their data, like databases, its
          network and leftover command containers. Named volumes, like caches, stay unless you
          pass --volumes. Files in the project stay. The next command starts the services fresh.

            rascal clean rspec
            rascal clean --all --volumes
      TEXT
      method_option :volumes, type: :boolean, desc: 'Also remove volumes, like caches'
      method_option :all, type: :boolean, desc: 'Clean the environments of all jobs'
      def clean(environment_name = nil)
        handle_error do
          Clean.new(options, environment_name).run
        end
      end

      desc 'update JOB | --all', "Pull a job's latest images"
      long_desc indented(<<~TEXT), wrap: false
          Pulls the latest images of the job and its services. Services that already run keep
          their old image until you run rascal clean.

            rascal update rspec
      TEXT
      method_option :all, type: :boolean, desc: 'Update the environments of all jobs'
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
          raise Thor::Error, "Unexpected #{parser.remaining.join(' ')} before --. Usage: rascal run [OPTIONS] JOB -- COMMAND"
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
