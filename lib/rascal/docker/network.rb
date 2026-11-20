module Rascal
  module Docker
    class Network
      include IOHelper

      attr_reader :prefixed_name

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
      rescue Interface::Error => e
        # Another rascal command for the same environment was faster.
        raise unless e.message.include?('already exists')
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
          info "Removing network #{@prefixed_name}"
          Docker.interface.run(
            'network',
            'rm',
            id,
          )
        end
      end

      # The full id, not the short one docker prints by default: a container
      # records the network it is attached to by full id, and
      # Container#remove_if_network_missing compares the two.
      def id
        @id ||= Docker.interface.run(
          'network',
          'ls',
          '--quiet',
          '--no-trunc',
          '--filter', "name=^#{@prefixed_name}$",
          output: :id,
        )
      end
    end
  end
end
