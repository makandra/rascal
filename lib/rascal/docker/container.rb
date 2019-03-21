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
        unless Docker.interface.inspect_image(@image, allow_failure: true)
          say "Downloading image for #{@name}"
          Docker.interface.pull(@image, stdout: stdout)
        end
      end

      def running?
        id && !!Docker.interface.container_info(id).dig('State', 'Running')
      end

      def exists?
        !!id
      end

      def start(network: nil, network_alias: nil)
        say "Starting container for #{@name}"
        create(network: network, network_alias: network_alias) unless exists?
        Docker.interface.start_container(id)
      end

      def create(network: nil, network_alias: nil)
        @id = Docker.interface.create_container(@image, @prefixed_name, network: network&.id, network_alias: network_alias)
      end

      def run_and_attach(*command, env: {}, network: nil, volumes: [], working_dir: nil, allow_failure: false)
        Docker.interface.run_and_attach(@image, *command,
          env: env,
          stdout: stdout,
          stderr: stderr,
          stdin: stdin,
          network: network&.id,
          volumes: volumes,
          working_dir: working_dir,
          allow_failure: allow_failure
        )
      end

      def clean
        Docker.interface.stop_container(id) if running?
        Docker.interface.remove_container(id) if exists?
      end

      private

      def id
        @id ||= Docker.interface.id_for_container_name(@prefixed_name)
      end
    end
  end
end
