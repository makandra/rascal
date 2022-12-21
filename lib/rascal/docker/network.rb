module Rascal
  module Docker
    class Network
      def initialize(name)
        @name = name
        @prefixed_name = "#{NAME_PREFIX}#{name}"
      end

      def create
        Docker.interface.run(
          'network',
          'create',
          @prefixed_name,
        )
      end

      def disconnect(container_id)
        Docker.interface.run(
          'network',
          'disconnect',
          id,
          container_id,
        )
      rescue Interface::Error => e
        raise unless e.message.include?('is not connected')
      end

      def exists?
        !!id
      end

      def clean
        if exists?
          Docker.interface.run(
            'network',
            'rm',
            id,
          )
        end
      end

      def id
        @id ||= Docker.interface.run(
          'network',
          'ls',
          '--quiet',
          '--filter', "name=^#{@prefixed_name}$",
          output: :id,
        )
      end
    end
  end
end
