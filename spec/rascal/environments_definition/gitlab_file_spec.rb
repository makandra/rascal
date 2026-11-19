require 'tmpdir'

module Rascal
  module EnvironmentsDefinition
    describe GitlabFile do

      around do |example|
        Dir.mktmpdir do |dir|
          @root = Pathname.new(dir)
          example.run
        end
      end

      def write(path, content)
        @root.join(path).dirname.mkpath
        @root.join(path).write(content)
      end

      def load(content = nil)
        write('.gitlab-ci.yml', content) if content
        described_class.new(@root.join('.gitlab-ci.yml'))
      end

      describe 'include:' do

        it 'merges local files, letting the including file win' do
          write('ci/base.yml', <<~YAML)
            variables:
              A: included
              B: included
            .template:
              image: template-image
          YAML

          config = load(<<~YAML).to_h
            include:
              - local: /ci/base.yml
            variables:
              B: main
          YAML

          expect(config).to eq(
            'variables' => { 'A' => 'included', 'B' => 'main' },
            '.template' => { 'image' => 'template-image' },
          )
        end

        it 'accepts a plain path, wildcards, and includes within included files' do
          write('ci/jobs/a.yml', "job-a:\n  image: a\n")
          write('ci/jobs/b.yml', "include: ci/nested.yml\njob-b:\n  image: b\n")
          write('ci/nested.yml', "job-nested:\n  image: nested\n")

          config = load("include: 'ci/jobs/*.yml'\n").to_h

          expect(config.keys).to contain_exactly('job-a', 'job-b', 'job-nested')
        end

        it 'skips includes it cannot read, and lists them' do
          file = load(<<~YAML)
            include:
              - project: group/templates
                file: ci.yml
              - https://example.com/ci.yml
              - template: Auto-DevOps.gitlab-ci.yml
            job:
              image: job-image
          YAML

          expect(file.to_h).to eq('job' => { 'image' => 'job-image' })
          expect(file.skipped_includes).to eq [
            { 'project' => 'group/templates', 'file' => 'ci.yml' },
            'https://example.com/ci.yml',
            { 'template' => 'Auto-DevOps.gitlab-ci.yml' },
          ]
        end

        it 'complains about a local include that does not exist, like GitLab' do
          expect { load("include: ci/missing.yml\n") }.to raise_error(Rascal::Error, 'The local include ci/missing.yml does not exist. Paths are relative to the project root.')
        end

      end

      describe '!reference' do

        it 'resolves references, also nested ones and ones into included files' do
          write('ci/base.yml', <<~YAML)
            .services:
              postgres:
                - name: postgres:15
                  alias: db
          YAML

          config = load(<<~YAML).to_h
            include: ci/base.yml
            .variables:
              shared:
                A: a
              more: !reference [.variables, shared]
            job:
              services: !reference [.services, postgres]
              variables: !reference [.variables, more]
          YAML

          expect(config['job']).to eq(
            'services' => [{ 'name' => 'postgres:15', 'alias' => 'db' }],
            'variables' => { 'A' => 'a' },
          )
        end

        it 'reports a missing reference as a problem of the job' do
          file = load(<<~YAML)
            job:
              image: job-image
              services: !reference [.missing, services]
          YAML

          expect(file.to_h['job']).to eq('image' => 'job-image', 'services' => nil)
          expect(file.job_problems['job']).to eq ['job: !reference [.missing, services] could not be found.']
        end

      end

      it 'uses the config after a header document with spec:' do
        config = load(<<~YAML).to_h
          spec:
            inputs:
              stage:
                default: test
          ---
          job:
            image: job-image
        YAML

        expect(config).to eq('job' => { 'image' => 'job-image' })
      end

      it 'refuses YAML that would create Ruby objects' do
        expect { load("job: !ruby/object:Object {}\n") }.to raise_error(Psych::DisallowedClass)
      end

    end
  end
end
