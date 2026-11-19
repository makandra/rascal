require 'yaml'

module Rascal
  module EnvironmentsDefinition
    # Loads a .gitlab-ci.yml into a hash, like GitLab does before it looks at jobs:
    #
    # - Merges local files from `include:`. Other includes (from other projects, URLs,
    #   templates or components) are left out and listed in #skipped_includes.
    # - Resolves `!reference [key, ...]` tags.
    # - Skips a header document with `spec:` before the actual config.
    #
    # Problems with references are collected per job in #job_problems instead of raising,
    # so one broken job does not keep rascal from working with the others.
    class GitlabFile
      # Marks where a `!reference` tag was, until it is resolved.
      REFERENCE_KEY = '!reference'

      # GitLab's limits for nested `!reference` tags and includes.
      MAX_REFERENCE_DEPTH = 10
      MAX_INCLUDE_DEPTH = 100

      attr_reader :skipped_includes, :job_problems

      def initialize(path)
        @root = path.parent
        @skipped_includes = []
        @job_problems = Hash.new { |hash, key| hash[key] = [] }
        @config = resolve_references(load_with_includes(path, 0))
      end

      def to_h
        @config
      end

      private

      def load_with_includes(path, depth)
        config = parse(path.read)
        includes = config.delete('include')
        return config unless includes

        if depth >= MAX_INCLUDE_DEPTH
          raise Error, "Too many nested includes in #{path}"
        end

        included = include_paths(includes).inject({}) do |merged, included_path|
          deep_merge(merged, load_with_includes(included_path, depth + 1))
        end
        # Like GitLab, the including file wins over the files it includes.
        deep_merge(included, config)
      end

      # The local files to include. Skips and remembers all other kinds of includes.
      def include_paths(includes)
        includes = [includes] unless includes.is_a?(Array)
        includes.flat_map do |entry|
          location = case entry
          when String
            entry.match?(%r{\Ahttps?://}) ? nil : entry
          when Hash
            entry['local']
          end

          if location
            local_paths(location.to_s)
          else
            @skipped_includes << entry
            []
          end
        end
      end

      # A local include is relative to the project root, and may use wildcards.
      def local_paths(location)
        pattern = location.sub(%r{\A/+}, '')
        paths = Dir.glob(pattern, base: @root.to_s).sort.collect { |relative| @root.join(relative) }
        if paths.empty?
          raise Error, "The local include #{location} does not exist. Paths are relative to the project root."
        end
        paths.select(&:file?)
      end

      # Parses YAML like YAML.safe_load with aliases, but keeps `!reference` tags as
      # { REFERENCE_KEY => [...] }, and uses the last document of the file.
      def parse(yaml)
        document = Psych.parse_stream(yaml).children.last
        return {} unless document

        mark_references(document)
        class_loader = Psych::ClassLoader::Restricted.new([], [])
        scanner = Psych::ScalarScanner.new(class_loader)
        result = Psych::Visitors::ToRuby.new(scanner, class_loader).accept(document)
        stringify_keys(result.is_a?(Hash) ? result : {})
      end

      def mark_references(node)
        node.children&.each_with_index do |child, index|
          if child.is_a?(Psych::Nodes::Sequence) && child.tag == '!reference'
            child.tag = nil
            marker = Psych::Nodes::Mapping.new
            marker.children << Psych::Nodes::Scalar.new(REFERENCE_KEY) << child
            node.children[index] = marker
          end
          mark_references(child)
        end
      end

      def resolve_references(config)
        config.to_h do |key, value|
          [key, resolve_references_in(value, config, key, 0)]
        end
      end

      def resolve_references_in(value, config, job_key, depth)
        if reference?(value)
          resolve_reference(value[REFERENCE_KEY], config, job_key, depth)
        elsif value.is_a?(Hash)
          value.to_h { |key, nested| [key, resolve_references_in(nested, config, job_key, depth)] }
        elsif value.is_a?(Array)
          value.collect { |nested| resolve_references_in(nested, config, job_key, depth) }
        else
          value
        end
      end

      def resolve_reference(location, config, job_key, depth)
        location = Array(location).collect(&:to_s)
        description = "!reference [#{location.join(', ')}]"
        if depth >= MAX_REFERENCE_DEPTH
          @job_problems[job_key] << "#{job_key}: #{description} is nested too deeply."
          return
        end

        target = location.inject(config) { |current, key| current.is_a?(Hash) ? current[key] : nil }
        if target.nil?
          @job_problems[job_key] << "#{job_key}: #{description} could not be found."
          return
        end

        resolve_references_in(target, config, job_key, depth + 1)
      end

      def reference?(value)
        value.is_a?(Hash) && value.keys == [REFERENCE_KEY]
      end

      def deep_merge(hash1, hash2)
        hash1.merge(hash2) do |_key, value1, value2|
          value1.is_a?(Hash) && value2.is_a?(Hash) ? deep_merge(value1, value2) : value2
        end
      end

      # YAML turns keys like `2.6:` into numbers. GitLab treats all keys as strings.
      def stringify_keys(value)
        case value
        when Hash then value.to_h { |key, nested| [key.to_s, stringify_keys(nested)] }
        when Array then value.collect { |nested| stringify_keys(nested) }
        else value
        end
      end
    end
  end
end
