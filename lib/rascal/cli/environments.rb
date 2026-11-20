require 'rascal'

module Rascal
  module CLI
    class Environments < Base
      def run
        project_jobs.names.each do |name|
          say name
        end
      end
    end
  end
end
