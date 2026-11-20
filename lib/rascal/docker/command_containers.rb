require 'securerandom'
require 'shellwords'

module Rascal
  module Docker
    # The one-off containers that run commands in an environment, each named like
    # `rascal-myapp-rspec-run-0123abcd` and removed when its command ends.
    class CommandContainers
      include IOHelper

      # Names of command containers end with this and a random suffix.
      RUN_SUFFIX = '-run-'

      attr_reader :entrypoint

      # `image` is a Docker::Image. `entrypoint` overrides the image's entrypoint, like
      # `image: entrypoint:` in GitLab. [] or [''] removes it.
      def initialize(name, image, entrypoint: nil)
        @name = name
        @prefixed_name = "#{NAME_PREFIX}#{name}"
        @image = image
        @entrypoint = entrypoint && (entrypoint.empty? ? [''] : entrypoint)
      end

      # Runs a command in a new container, attached to rascal's output, and returns its
      # Process::Status. If rascal gets a signal, like when a script or an agent gives up on a
      # command, it removes the container, which would keep running otherwise. With `tty`, the
      # container gets a terminal. With `forward_stdin`, it reads rascal's stdin.
      def run(*command, env:, network:, volumes:, working_dir:, tty:, forward_stdin:)
        name = "#{@prefixed_name}#{RUN_SUFFIX}#{SecureRandom.hex(4)}"
        remove_on_signal(name) do
          Docker.interface.run_and_attach(
            'container',
            'run',
            '--rm',
            '--name', name,
            '-a', 'STDOUT',
            '-a', 'STDERR',
            *(['-a', 'STDIN', '--interactive'] if forward_stdin),
            *('--tty' if tty),
            *(['--entrypoint', @entrypoint.first.to_s] if @entrypoint),
            *(['-w', working_dir] if working_dir),
            *volumes.flat_map { |volume| ['-v', volume.to_param] },
            *Docker.env_args(env),
            '--network', network.id,
            @image.name,
            *@entrypoint&.drop(1),
            # An entrypoint like `sh -c` takes the command as one string.
            *(shell_entrypoint? ? [Shellwords.join(command)] : command),
            redirect_io: { out: stdout, err: stderr, in: stdin },
            allow_failure: true,
          )
        end
      end

      # Names of containers of commands that run now, or were left over.
      def names
        Docker.interface.run('container', 'ps', '--all', '--format', '{{.Names}}', '--filter', name_filter, output: :text).to_s.split
      end

      # Removes containers left over from commands that were killed.
      def clean
        ids = Docker.interface.run('container', 'ps', '--all', '--quiet', '--filter', name_filter, output: :text).to_s.split
        return if ids.empty?

        info "Removing #{ids.size} leftover command container#{'s' if ids.size > 1} for #{@name}"
        Docker.interface.run('container', 'rm', '--force', '--volumes', *ids)
      end

      private

      # Whether the entrypoint (from the CI config, or else the image's) is a shell that
      # expects the command as one string, like `sh -c`, `bash -lc` or `sh -ec`.
      def shell_entrypoint?
        Array(@entrypoint || @image.entrypoint).last.to_s.match?(/\A-[a-zA-Z]*c[a-zA-Z]*\z/)
      end

      # Matches only containers of commands, not service containers of a job whose name starts the
      # same, like `job-run-tests` for `job`.
      def name_filter
        "name=^/#{Regexp.escape(@prefixed_name)}#{RUN_SUFFIX}[0-9a-f]{8}$"
      end

      # Runs `docker` directly instead of through Docker.interface, which uses threads and locks
      # that a signal handler must not.
      def remove_on_signal(name)
        previous_handlers = %w[INT TERM HUP].to_h do |signal|
          handler = Signal.trap(signal) do
            pid = Process.spawn('docker', 'container', 'rm', '--force', '--volumes', name, out: File::NULL, err: File::NULL)
            Process.wait(pid)
            exit(128 + Signal.list.fetch(signal))
          end
          [signal, handler]
        end
        yield
      ensure
        previous_handlers&.each { |signal, handler| Signal.trap(signal, handler) }
      end
    end
  end
end
