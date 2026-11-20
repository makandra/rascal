module Rascal
  module EnvironmentsDefinition
    # Resolves CI variables the way a GitLab job sees them:
    #
    # - Definitions come in layers. Later layers override earlier ones.
    # - A value may reference other variables as `$NAME`, `${NAME}` or `%NAME%`.
    # - A value that references its own name gets the definition from the layer below,
    #   so the .rascal block can extend a job's variable with `PATH: $PATH:/more`.
    # - `$NAME` and `${NAME}` expand to an empty string if NAME is undefined.
    #   `%NAME%` stays as it is, so strings like `%Y%m%d` survive.
    # - `$$` stands for a literal `$`.
    # - A variable defined as `{ value: ..., expand: false }` is used as is.
    # - Variables that reference each other in a circle are an error.
    # - A variable defined as nil is removed, as if no lower layer defined it. This is
    #   rascal's own extension, for removing predefined variables like `CI`.
    #
    # GitLab expands in two steps: the GitLab server expands references to defined variables
    # (see Gitlab::Ci::Variables::Collection#sort_and_expand_all), then the runner expands
    # the rest and turns `$$` into `$`. This class does both in one step.
    class GitlabVariables
      NAME = /[a-zA-Z_][a-zA-Z0-9_]*/
      REFERENCE = /\$\$|%%|\$(?<name>#{NAME})|\$\{(?<name>#{NAME})\}|%(?<percent_name>#{NAME})%/

      Definition = Struct.new(:value, :expand)

      # Takes layers of variable definitions as hashes, from the lowest to the highest priority.
      def initialize(*layers)
        # For each name, all its definitions from the lowest to the highest layer.
        @definitions = Hash.new { |hash, name| hash[name] = [] }
        layers.each { |layer| add(layer) }
      end

      # Returns a new instance with another layer of definitions on top.
      def merge(definitions)
        merged = self.class.new
        @definitions.each { |name, layers| merged.layers(name).concat(layers) }
        merged.add(definitions)
        merged
      end

      # All variables, with their references expanded.
      def to_h
        defined_names.to_h { |name| [name, resolve(name)] }
      end

      # The variables whose values directly reference undefined variables, as a hash
      # from each variable's name to the names of the undefined ones. A variable that
      # references its own name without a lower definition does not count, since
      # appending to an unset variable is common.
      def undefined_references
        defined_names.each_with_object({}) do |name, result|
          layer = @definitions[name].size - 1
          definition = @definitions[name][layer]
          next unless definition.expand

          undefined = []
          expand_with(definition.value, [name, layer], [[name, layer]], direct_only: true) { |undefined_name| undefined << undefined_name }
          result[name] = undefined.uniq if undefined.any?
        end
      end

      # Expands variable references in the given string. Yields the name of each
      # undefined variable it encounters.
      def expand(string, &on_undefined)
        expand_with(string.to_s, nil, [], &on_undefined)
      end

      protected

      def layers(name)
        @definitions[name]
      end

      def add(definitions)
        (definitions || {}).each do |name, value|
          @definitions[name.to_s] << normalize(value)
        end
      end

      private

      def defined_names
        @definitions.keys.reject { |name| @definitions[name].last.value.nil? }
      end

      def normalize(value)
        if value.nil?
          Definition.new(nil, true)
        elsif value.is_a?(Hash)
          Definition.new(value['value'].to_s, value.fetch('expand', true))
        else
          Definition.new(value.to_s, true)
        end
      end

      # Resolves the given layer of a variable, the latest one by default.
      def resolve(name, layer = @definitions[name].size - 1, visiting = [], &on_undefined)
        definition = @definitions[name][layer]
        if !definition.expand
          definition.value
        elsif visiting.include?([name, layer])
          circle = [*visiting.drop_while { |entry| entry != [name, layer] }, [name, layer]].collect(&:first)
          raise Error, "The variables #{circle.join(' -> ')} reference each other in a circle. GitLab rejects this as well."
        else
          expand_with(definition.value, [name, layer], [*visiting, [name, layer]], &on_undefined)
        end
      end

      # `current` is the variable whose value is being expanded, as [name, layer].
      # With `direct_only`, only undefined variables in `string` itself are yielded, not
      # those in the values of variables it references.
      def expand_with(string, current, visiting, direct_only: false, &on_undefined)
        string.gsub(REFERENCE) do
          match = Regexp.last_match
          if match[0] == '$$'
            '$'
          elsif match[0] == '%%'
            '%%'
          else
            name = match[:name] || match[:percent_name]
            layer = referenced_layer(name, current)
            if layer
              direct_only ? resolve(name, layer, visiting) : resolve(name, layer, visiting, &on_undefined)
            elsif match[:name]
              # Not for variables that are only defined lower or removed on purpose.
              on_undefined&.call(name) unless @definitions.key?(name)
              ''
            else
              match[0]
            end
          end
        end
      end

      # The layer a reference to `name` points to, or nil if it is undefined or removed.
      def referenced_layer(name, current)
        return unless @definitions.key?(name)

        layer = if current && current.first == name
          # A variable referencing itself means its definition in a lower layer.
          current.last.positive? ? current.last - 1 : nil
        else
          @definitions[name].size - 1
        end
        layer unless layer.nil? || @definitions[name][layer].value.nil?
      end
    end
  end
end
