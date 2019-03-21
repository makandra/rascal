module Rascal
  module Docker
    class Network
      def initialize(name)
        @name = name
        @prefixed_name = "#{NAME_PREFIX}#{name}"
      end

      def create
        Docker.interface.create_network(@prefixed_name)
      end

      def exists?
        !!Docker.interface.id_for_network_name(@prefixed_name)
      end

      def clean
        Docker.interface.remove_network(id) if exists?
      end

      def id
        @id ||= Docker.interface.id_for_network_name(@prefixed_name)
      end
    end
  end
end
