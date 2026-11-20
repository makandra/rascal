module Rascal
  module Docker
    module Volume
      class Named
        include IOHelper

        def initialize(name, container_path)
          @prefixed_name = "#{NAME_PREFIX}#{name}"
          @container_path = container_path
        end

        def to_param
          "#{@prefixed_name}:#{@container_path}"
        end

        def status
          { 'path' => @container_path, 'volume' => @prefixed_name, 'exists' => exists? }
        end

        def clean
          if exists?
            info "Removing volume #{@prefixed_name}"
            Docker.interface.run(
              'volume',
              'rm',
              @prefixed_name,
            )
          end
        end

        def exists?
          !Docker.interface.run(
            'volume',
            'ls',
            '--quiet',
            '--filter', "name=^#{@prefixed_name}$",
            output: :text,
          ).to_s.empty?
        end
      end

      class Bind
        def initialize(local_path, container_path, read_only: false)
          @local_path = local_path
          @container_path = container_path
          @read_only = read_only
        end

        def to_param
          "#{@local_path}:#{@container_path}#{':ro' if @read_only}"
        end

        def status
          { 'path' => @container_path, 'directory' => @local_path.to_s }
        end

        def clean
          # nothing to do
        end
      end
    end
  end
end
