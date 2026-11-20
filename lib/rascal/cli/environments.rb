require 'rascal'

module Rascal
  module CLI
    class Environments < Base
      def run
        environment_definition.available_environment_names.each do |name|
          say name
        end
      end
    end
  end
end
