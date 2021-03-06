module Rascal
  module Docker
    module Volume
      class Base
        include IOHelper
      end

      class Named < Base
        def initialize(name, container_path)
          @prefixed_name = "#{NAME_PREFIX}#{name}"
          @container_path = container_path
        end

        def to_param
          "#{@prefixed_name}:#{@container_path}"
        end

        def clean
          if exists?
            say "Removing volume #{@prefixed_name}"
            Docker.interface.run(
              'volume',
              'rm',
              @prefixed_name,
            )
          end
        end

        def exists?
          Docker.interface.run(
            'volume',
            'ls',
            '--quiet',
            '--filter', "name=^#{@prefixed_name}$",
            output: :id,
          )
        end
      end

      class Bind < Base
        def initialize(local_path, container_path)
          @local_path = local_path
          @container_path = container_path
        end

        def to_param
          "#{@local_path}:#{@container_path}"
        end

        def clean
          # nothing to do
        end
      end
    end
  end
end
