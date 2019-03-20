module Rascal
  module EnvironmentsDefinition
    autoload :Gitlab, 'rascal/environments_definition/gitlab'

    class << self
      def detect(working_dir)
        definition_formats.each do |format|
          definition = format.detect(working_dir)
          return definition if definition
        end
        nil
      end

      private

      def definition_formats
        [
          Gitlab
        ]
      end
    end
  end
end
