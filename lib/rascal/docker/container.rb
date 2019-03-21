module Rascal
  module Docker
    class Container
      include IOHelper

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
            output: :json
          ).first
          !!container_info.dig('State', 'Running')
        else
          false
        end
      end

      def exists?
        !!id
      end

      def start(network: nil, network_alias: nil)
        say "Starting container for #{@name}"
        create(network: network, network_alias: network_alias) unless exists?
        Docker.interface.run(
          'container',
          'start',
          id,
        )
      end

      def create(network: nil, network_alias: nil)
        @id = Docker.interface.run(
          'container',
          'create',
          '--name', @prefixed_name,
          *(['--network', network.id] if network),
          *(['--network-alias', network_alias] if network_alias),
          @image,
          output: :id
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
          *(env.flat_map { |key, value| ['-e', "#{key}=#{value}"] }),
          *(['--network', network.id] if network),
          @image,
          *command,
          redirect_io: {
            out: stdout,
            err: stderr,
            in: stdin,
          },
          allow_failure: allow_failure
        )
      end

      def clean
        stop_container if running?
        remove_container if exists?
      end

      private

      def id
        @id ||= Docker.interface.run(
          'container',
          'ps',
          '--all',
          '--quiet',
          '--filter', "name=^/#{@prefixed_name}$",
          output: :id
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
    end
  end
end
