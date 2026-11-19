require 'open3'
require 'yaml'

module Rascal
  module EnvironmentsDefinition
    # Loads a .gitlab-ci.yml into a hash, like GitLab does before it looks at jobs:
    #
    # - Merges local files from `include:`. Other includes (from other projects, URLs,
    #   templates or components) are left out and listed in #skipped_includes.
    # - Uses the config document after a header document with `spec:`.
    #
    # `!reference [key, ...]` tags become { REFERENCE_KEY => [key, ...] }. Like GitLab,
    # Gitlab resolves them after `extends:`.
    class GitlabFile
      # Marks where a `!reference` tag was, until it is resolved.
      REFERENCE_KEY = '!reference'

      # Include locations that are URLs.
      REMOTE_LOCATION = %r{\A(https?|ssh|git)://}

      attr_reader :skipped_includes

      class << self
        def reference?(value)
          value.is_a?(Hash) && value.keys == [REFERENCE_KEY]
        end

        # Merges like ActiveSupport's deep_merge, which GitLab uses for includes and `extends:`.
        # A reference is replaced as a whole, like GitLab's unresolved reference objects.
        def deep_merge(hash1, hash2)
          hash1.merge(hash2) do |_key, value1, value2|
            if value1.is_a?(Hash) && value2.is_a?(Hash) && !reference?(value1) && !reference?(value2)
              deep_merge(value1, value2)
            else
              value2
            end
          end
        end
      end

      def initialize(path)
        @root = path.parent
        @skipped_includes = []
        @config = load_with_includes(path, [])
      end

      def to_h
        @config
      end

      private

      def load_with_includes(path, including_paths)
        config = parse(path.read, path)
        includes = config.delete('include')
        return config unless includes

        included = include_paths(includes, path).inject({}) do |merged, included_path|
          if including_paths.include?(included_path) || included_path == path
            raise Error, "#{relative(included_path)} includes itself, directly or through other files."
          end

          self.class.deep_merge(merged, load_with_includes(included_path, [*including_paths, path]))
        end
        # Like GitLab, the including file wins over the files it includes.
        self.class.deep_merge(included, config)
      end

      # The local files to include. Skips and remembers all other kinds of includes.
      def include_paths(includes, including_path)
        includes = [includes] unless includes.is_a?(Array)
        includes.flat_map do |entry|
          location = case entry
          when String then entry.match?(REMOTE_LOCATION) ? nil : entry
          when Hash then entry['local']
          end

          if location.nil?
            @skipped_includes << entry
            []
          elsif location.to_s.include?('*')
            wildcard_paths(location.to_s, including_path)
          else
            local_path(location.to_s, entry)
          end
        end
      end

      # A local include is relative to the project root.
      def local_path(location, entry)
        path = @root.join(location.sub(%r{\A/+}, ''))
        inside_root!(path, location)
        if path.file?
          [path]
        elsif entry.is_a?(Hash) && entry.key?('rules')
          # Rules like `exists:` may exclude a missing file in GitLab. rascal cannot evaluate rules.
          @skipped_includes << entry
          []
        else
          raise Error, "The local include #{location} does not exist. Paths are relative to the project root."
        end
      end

      # Like GitLab (see Repository#search_files_by_wildcard_path), `*` matches within a directory,
      # `**` across directories, `**/` also matches no directory, and all of them match dotfiles.
      # A pattern without matches includes nothing, and never the including file.
      def wildcard_paths(location, including_path)
        pattern = location.sub(%r{\A/+}, '')
        regexp = Regexp.new('\A' + Regexp.escape(pattern).gsub('\*\*/', '(.*?/)?').gsub('\*\*', '.*').gsub('\*', '[^/]*') + '\z')
        project_files
          .select { |relative| relative.match?(regexp) }
          .collect { |relative| @root.join(relative) }
          .select { |path| path.file? && path != including_path }
          .each { |path| inside_root!(path, location) }
      end

      # The files GitLab would see: those in Git, plus new ones that are not ignored. Without Git,
      # all files.
      def project_files
        @project_files ||= begin
          output, status = Open3.capture2('git', '-C', @root.to_s, 'ls-files', '-z', '--cached', '--others', '--exclude-standard', err: File::NULL)
          status.success? ? output.split("\0").sort : Dir.glob('**/*', File::FNM_DOTMATCH, base: @root.to_s).sort
        rescue SystemCallError
          Dir.glob('**/*', File::FNM_DOTMATCH, base: @root.to_s).sort
        end
      end

      def inside_root!(path, location)
        root = @root.realpath.to_s
        real = path.exist? ? path.realpath.to_s : path.cleanpath.to_s
        unless real == root || real.start_with?("#{root}/")
          raise Error, "The local include #{location} is outside the project."
        end
      end

      def relative(path)
        path.relative_path_from(@root).to_s
      end

      # Parses YAML like YAML.safe_load with aliases, but keeps `!reference` tags
      # as markers, and picks the config document like GitLab.
      def parse(yaml, path)
        document = config_document(Psych.parse_stream(yaml, filename: relative(path)).children)
        return {} unless document

        mark_references(document)
        # Like GitLab, allows symbols, but no other Ruby objects.
        class_loader = Psych::ClassLoader::Restricted.new(['Symbol'], [])
        scanner = Psych::ScalarScanner.new(class_loader)
        result = Psych::Visitors::ToRuby.new(scanner, class_loader).accept(document)
        stringify_keys(result.is_a?(Hash) ? result : {})
      rescue Psych::Exception => e
        raise Error, "Could not read #{relative(path)}: #{e.message}"
      end

      # Like GitLab, ignores empty documents, and uses the second document only when
      # the first one is a header with `spec:`.
      def config_document(documents)
        documents = documents.reject { |document| document.root.nil? || (document.root.is_a?(Psych::Nodes::Scalar) && document.root.value.empty?) }
        first = documents.first
        header = first&.root.is_a?(Psych::Nodes::Mapping) &&
          first.root.children.each_slice(2).any? { |key, _| key.is_a?(Psych::Nodes::Scalar) && key.value == 'spec' }
        header && documents.size > 1 ? documents[1] : first
      end

      def mark_references(node)
        node.children&.each_with_index do |child, index|
          if child.respond_to?(:tag) && child.tag == '!reference'
            child.tag = nil
            # The anchor belongs to the reference, so aliases get the resolved value too.
            marker = Psych::Nodes::Mapping.new(child.anchor)
            child.anchor = nil
            # A reference that is not a list gets resolved to a problem.
            child = Psych::Nodes::Scalar.new('') unless child.is_a?(Psych::Nodes::Sequence)
            marker.children << Psych::Nodes::Scalar.new(REFERENCE_KEY) << child
            node.children[index] = marker
          end
          mark_references(child)
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
