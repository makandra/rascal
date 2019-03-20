module Rascal
  module Docker
    class Network
      def initialize(name)
        @name = name
        @prefixed_name = "#{NAME_PREFIX}#{name}"
      end

      def create
        Interface.create_network(@prefixed_name)
      end

      def exists?
        !!Interface.id_for_network_name(@prefixed_name)
      end

      def clean
        Interface.remove_network(id) if exists?
      end

      def id
        @id ||= Interface.id_for_network_name(@prefixed_name)
      end
    end
  end
end
