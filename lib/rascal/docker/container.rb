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
        if id
          container_info = Docker.interface.run(
            'container',
            'inspect',
            id,
            output: :json,
          ).first
          !!container_info.dig('State', 'Running')
        else
          false
        end
      end

      def exists?
        !!id
      end

      def start(network: nil, network_alias: nil, volumes: [], env: {})
        say "Starting container for #{@name}"
        create(network: network, network_alias: network_alias, volumes: volumes) unless exists?
        Docker.interface.run(
          'container',
          'start',
          *env_args(env),
          id,
        )
      end

      def create(network: nil, network_alias: nil, volumes: [])
        @id = Docker.interface.run(
          'container',
          'create',
          '--name', @prefixed_name,
          *(volumes.flat_map { |v| ['-v', v.to_param] }),
          *(['--network', network.id] if network),
          *(['--network-alias', network_alias] if network_alias),
          @image,
          output: :id,
        )
      end

      def run_and_attach(*command, env: {}, network: nil, volumes: [], working_dir: nil, allow_failure: false)
        Docker.interface.run_and_attach(
          'container',
          'run',
          '--rm',
          '-a', 'STDOUT',
          '-a', 'STDERR',
          '-a', 'STDIN',
          '--interactive',
          '--tty',
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

      private

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
