module Rascal
  module Docker
    class Container
      include IOHelper

      attr_reader :image

      def initialize(name, image)
        @name = name
        @prefixed_name = "#{NAME_PREFIX}#{name}"
        @image = image
      end

      def download_missing
        unless image_exists?
          say "Downloading image for #{@name}"
          Docker.interface.run(
            'pull',
            @image,
            stdout: stdout,
          )
        end
      end

      def running?
        !!container_info&.dig('State', 'Running')
      end

      def exists?
        !!id
      end

      # Docker resolves a container's network by the id it recorded when the
      # container was created, and refuses to start it once that network is
      # gone:
      #
      #   failed to set up container networking: network 36243f82141a... not found
      #
      # `docker network prune` (and `docker system prune`) leaves exactly that
      # behind, because it removes networks whose containers are all stopped —
      # the normal state of an environment between runs. Reconnecting does not
      # help, since docker resolves the recorded id before it looks at the
      # container's current endpoints, so the container has to go. Nothing in a
      # service container is worth preserving; #start creates a new one.
      def remove_if_network_missing(network)
        return unless exists?
        attached = attached_network_ids
        return if attached.empty? || attached.include?(network.id)

        say "Removing container for #{@name}, its network no longer exists"
        remove_container
        @id = nil
      end

      def start(network: nil, network_alias: nil, volumes: [], env: {}, command: [])
        say "Starting container for #{@name}"
        create(network: network, network_alias: network_alias, volumes: volumes, env: env, command: command) unless exists?
        Docker.interface.run(
          'container',
          'start',
          id,
        )
      end

      def create(network: nil, network_alias: nil, volumes: [], env: {}, command: [])
        @id = Docker.interface.run(
          'container',
          'create',
          '--name', @prefixed_name,
          *(volumes.flat_map { |v| ['-v', v.to_param] }),
          *env_args(env),
          *(['--network', network.id] if network),
          *(['--network-alias', network_alias] if network_alias),
          @image,
          *command,
          output: :id,
        )
      end

      def run_and_attach(*command, env: {}, network: nil, volumes: [], working_dir: nil, allow_failure: false, tty: true)
        Docker.interface.run_and_attach(
          'container',
          'run',
          '--rm',
          '-a', 'STDOUT',
          '-a', 'STDERR',
          *(['-a', 'STDIN', '--interactive', '--tty'] if tty),
          *(['-w', working_dir] if working_dir),
          *(volumes.flat_map { |v| ['-v', v.to_param] }),
          *env_args(env),
          *(['--network', network.id] if network),
          @image,
          *command,
          redirect_io: {
            out: stdout,
            err: stderr,
            in: stdin,
          },
          allow_failure: allow_failure,
        )
      end

      def clean
        if running?
          say "Stopping container for #{@name}"
          stop_container
        end
        if exists?
          say "Removing container for #{@name}"
          remove_container
        end
      end

      def update(skip: [])
        return if skip.include?(@image)
        say "Updating image #{@image}"
        Docker.interface.run(
          'pull',
          @image,
          stdout: stdout,
        )
        @image
      end

      def id
        @id ||= Docker.interface.run(
          'container',
          'ps',
          '--all',
          '--quiet',
          '--filter', "name=^/#{@prefixed_name}$",
          output: :id,
        )
      end

      private

      # A fresh `docker container inspect`, or nil if there is no container.
      def container_info
        return unless id
        Docker.interface.run(
          'container',
          'inspect',
          id,
          output: :json,
        ).first
      end

      # Ids of the networks the container is attached to. Empty for a container
      # that was created but never started.
      def attached_network_ids
        networks = container_info&.dig('NetworkSettings', 'Networks') || {}
        networks.each_value.filter_map { |n| n['NetworkID'] }.reject(&:empty?).uniq
      end

      def image_exists?
        Docker.interface.run(
          'image',
          'inspect',
          @image,
          output: :json,
          allow_failure: true,
        ).first
      end

      def stop_container
        Docker.interface.run(
          'container',
          'stop',
          id,
        )
      end

      def remove_container
        Docker.interface.run(
          'container',
          'rm',
          id,
        )
      end

      def env_args(env)
        env.flat_map { |key, value| ['-e', "#{key}=#{value}"] }
      end
    end
  end
end
