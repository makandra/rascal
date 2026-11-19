module Rascal
  module EnvironmentsDefinition
    describe GitlabVariables do

      describe '#to_h' do

        it 'lets later definitions override earlier ones' do
          variables = described_class.new({ 'A' => 'first', 'B' => 'first' }, { 'B' => 'second' })

          expect(variables.to_h).to eq('A' => 'first', 'B' => 'second')
        end

        it 'expands $NAME and ${NAME}' do
          variables = described_class.new('DIR' => '/repo', 'A' => '$DIR/a', 'B' => '${DIR}b')

          expect(variables.to_h).to include('A' => '/repo/a', 'B' => '/repob')
        end

        it 'expands chains of references, regardless of their order' do
          variables = described_class.new('C' => '$B/c', 'B' => '$A/b', 'A' => 'a')

          expect(variables.to_h).to include('C' => 'a/b/c')
        end

        it 'expands references to variables from earlier definitions' do
          variables = described_class.new({ 'DIR' => '/repo' }, { 'CACHE' => '$DIR/cache' })

          expect(variables.to_h).to include('CACHE' => '/repo/cache')
        end

        it 'expands undefined variables to an empty string' do
          variables = described_class.new('A' => 'x${UNDEFINED}y')

          expect(variables.to_h).to eq('A' => 'xy')
        end

        it 'turns $$ into a literal $' do
          variables = described_class.new('A' => 'a', 'PRICE' => '$$A costs $$5')

          expect(variables.to_h).to include('PRICE' => '$A costs $5')
        end

        it 'does not expand variables defined with expand: false' do
          variables = described_class.new('A' => 'a', 'RAW' => { 'value' => '$A', 'expand' => false }, 'B' => '$RAW')

          expect(variables.to_h).to include('RAW' => '$A', 'B' => '$A')
        end

        it 'takes the value of variables in their long form' do
          variables = described_class.new('A' => { 'value' => 'a', 'description' => 'Some variable' })

          expect(variables.to_h).to eq('A' => 'a')
        end

        it 'complains about variables that reference each other in a circle, like GitLab does' do
          variables = described_class.new('A' => '$B', 'B' => '${C}', 'C' => '$A')

          expect { variables.to_h }.to raise_error(Rascal::Error, 'The variables A -> B -> C -> A reference each other in a circle. GitLab rejects this as well.')
        end

        it 'expands a reference to the own name to the earlier definition of that name' do
          variables = described_class.new({ 'PATH' => '/usr/bin' }, { 'PATH' => '$PATH:/repo/bin' }, { 'PATH' => '${PATH}:/more' })

          expect(variables.to_h).to eq('PATH' => '/usr/bin:/repo/bin:/more')
        end

        it 'expands a reference to the own name to an empty string without an earlier definition' do
          variables = described_class.new('PATH' => '$PATH:/bin')

          expect(variables.to_h).to eq('PATH' => ':/bin')
        end

        it 'lets other variables see the latest definition of a name' do
          variables = described_class.new({ 'DIR' => '/a' }, { 'DIR' => '$DIR/b', 'FILE' => '$DIR/file' })

          expect(variables.to_h).to eq('DIR' => '/a/b', 'FILE' => '/a/b/file')
        end

        it 'expands %NAME% if NAME is defined, and keeps it otherwise' do
          variables = described_class.new('A' => 'a', 'B' => '%A%-%UNDEFINED%', 'DATE' => '%Y%m%d', 'PERCENT' => '100%%')

          expect(variables.to_h).to include('B' => 'a-%UNDEFINED%', 'DATE' => '%Y%m%d', 'PERCENT' => '100%%')
        end

        it 'only treats names starting with a letter or underscore as references' do
          variables = described_class.new('_A1' => 'a', 'B' => '$_A1 $1 ${2}')

          expect(variables.to_h).to include('B' => 'a $1 ${2}')
        end

      end

      describe '#expand' do

        it 'expands references in the given string' do
          variables = described_class.new('TAG' => '1.2')

          expect(variables.expand('image:$TAG')).to eq 'image:1.2'
        end

        it 'yields undefined variables' do
          variables = described_class.new
          undefined = []

          expect(variables.expand('$A-${B}') { |name| undefined << name }).to eq '-'
          expect(undefined).to eq ['A', 'B']
        end

      end

      describe '#merge' do

        it 'returns new variables with more definitions on top, which can reference the existing ones' do
          variables = described_class.new('A' => 'a', 'B' => 'b')
          merged = variables.merge('B' => '$A-overridden')

          expect(merged.to_h).to eq('A' => 'a', 'B' => 'a-overridden')
          expect(variables.to_h).to eq('A' => 'a', 'B' => 'b')
        end

        it 'lets new definitions extend existing ones of the same name' do
          variables = described_class.new('OPTS' => '-a')

          expect(variables.merge('OPTS' => '$OPTS -b').to_h).to eq('OPTS' => '-a -b')
        end

        it 'keeps the expand: false of existing definitions' do
          variables = described_class.new('A' => 'a', 'RAW' => { 'value' => '$A', 'expand' => false })

          expect(variables.merge({}).to_h).to include('RAW' => '$A')
        end

      end

    end
  end
end
