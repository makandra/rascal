require 'tmpdir'

module Rascal
  module Gitlab
    describe ConfigFile do

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

        it 'matches wildcards like GitLab, including dotfiles and subdirectories with **, but not the including file' do
          write('ci/a.yml', "job-a:\n  image: a\n")
          write('ci/.hidden.yml', "job-hidden:\n  image: hidden\n")
          write('ci/sub/b.yml', "job-b:\n  image: b\n")
          write('ci/main.yml', "include: 'ci/*.yml'\njob-main:\n  image: main\n")

          expect(load("include: ci/main.yml\n").to_h.keys).to contain_exactly('job-a', 'job-hidden', 'job-main')
          expect(load("include: 'ci/**.yml'\n").to_h.keys).to contain_exactly('job-a', 'job-hidden', 'job-b', 'job-main')
          expect(load("include: 'ci/**/*.yml'\n").to_h.keys).to contain_exactly('job-a', 'job-hidden', 'job-b', 'job-main')
          expect(load("include: 'nothing/*.yml'\njob:\n  image: job\n").to_h.keys).to eq ['job']
        end

        it 'only matches wildcards against files Git does not ignore, like the files GitLab sees' do
          system('git', 'init', '-q', @root.to_s, exception: true)
          write('.gitignore', "ignored/\n")
          write('ci/a.yml', "job-a:\n  image: a\n")
          write('ignored/b.yml', "job-b:\n  image: b\n")

          expect(load("include: '**/*.yml'\n").to_h.keys).to eq ['job-a']
        end

        it 'skips a missing file whose include has rules, since rascal cannot evaluate them' do
          file = load(<<~YAML)
            include:
              - local: ci/optional.yml
                rules:
                  - exists: [ci/optional.yml]
            job:
              image: job-image
          YAML

          expect(file.to_h.keys).to eq ['job']
          expect(file.skipped_includes).to eq [{ 'local' => 'ci/optional.yml', 'rules' => [{ 'exists' => ['ci/optional.yml'] }] }]
        end

        it 'complains about files that include each other' do
          write('ci/a.yml', "include: ci/b.yml\n")
          write('ci/b.yml', "include: ci/a.yml\n")

          expect { load("include: ci/a.yml\n") }.to raise_error(Rascal::Error, 'ci/a.yml includes itself, directly or through other files.')
        end

        it 'refuses to include files outside the project' do
          @root.join('../outside.yml').write("job:\n  image: outside\n")

          expect { load("include: ../outside.yml\n") }.to raise_error(Rascal::Error, 'The local include ../outside.yml is outside the project.')
        end

        it 'complains about a local include that does not exist, like GitLab' do
          expect { load("include: ci/missing.yml\n") }.to raise_error(Rascal::Error, 'The local include ci/missing.yml does not exist. Paths are relative to the project root.')
        end

      end

      describe '!reference' do

        it 'keeps references as markers, to be resolved after extends' do
          config = load(<<~YAML).to_h
            job:
              services: !reference [.services, postgres]
          YAML

          expect(config['job']).to eq('services' => { '!reference' => ['.services', 'postgres'] })
        end

        it 'keeps the anchor of a reference, so aliases get the marker too' do
          config = load(<<~YAML).to_h
            .template:
              variables: &shared !reference [.base, variables]
            job:
              variables: *shared
          YAML

          expect(config['job']).to eq('variables' => { '!reference' => ['.base', 'variables'] })
        end

      end

      describe 'documents' do

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

        it 'uses the first document without a spec: header, and ignores empty documents, like GitLab' do
          expect(load("job:\n  image: first\n---\n").to_h).to eq('job' => { 'image' => 'first' })
          expect(load("job:\n  image: first\n---\njob:\n  image: second\n").to_h).to eq('job' => { 'image' => 'first' })
        end

      end

      it 'explains YAML errors, naming the file' do
        write('ci/broken.yml', "job:\n  image: [unclosed\n")

        expect { load("include: ci/broken.yml\n") }.to raise_error(Rascal::Error, /\ACould not read ci\/broken.yml: .*line 2/)
      end

      it 'allows symbols, like GitLab' do
        expect(load("job:\n  variables:\n    MODE: :fast\n").to_h).to eq('job' => { 'variables' => { 'MODE' => :fast } })
      end

      it 'refuses YAML that would create Ruby objects' do
        expect { load("job: !ruby/object:Object {}\n") }.to raise_error(Rascal::Error, /Tried to load unspecified class: Object/)
      end

    end
  end
end
