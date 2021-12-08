module Rascal
  module EnvironmentsDefinition
    describe Gitlab do

      def from_config(yaml, name)
        config_path = double(read: yaml, parent: double(to_s: '/path/to/repo', basename: 'repo'))
        described_class.new(config_path).environment(name)
      end

      describe '#environment' do

        it 'returns a environment parsed from the config' do
          environment = from_config(<<~YAML, 'job-1')
            job-1:
              image: job-1-image:latest
            job-2:
              image: job-2-image:latest
          YAML

          expect(environment.name).to eq 'job-1'
          expect(environment.services).to eq []
          expect(environment.container.image).to eq 'job-1-image:latest'
        end

        it 'adds services' do
          environment = from_config(<<~YAML, 'job')
            job:
              image: job-1-image:latest
              services:
              - name: service-1-image
                alias: service-1
                command: bin/start
          YAML

          expect(environment.services.size).to eq 1
          service = environment.services.first
          expect(service.container.image).to eq 'service-1-image'
          expect(service.alias).to eq 'service-1'
          expect(service.command).to eq ['bin/start']
        end

        it 'sets env variables' do
          environment = from_config(<<~YAML, 'job')
            job:
              image: job-1-image:latest
              variables:
                FOO: foo
                BAR: bar
          YAML

          expect(environment.env_variables).to eq(
            'FOO' => 'foo',
            'BAR' => 'bar',
          )
        end

        it 'adds a build and repo volume by default' do
          environment = from_config(<<~YAML, 'job')
            job:
              image: job-1-image:latest
          YAML

          expect(environment.volumes.size).to eq 2
          expect(environment.volumes.collect(&:to_param)).to match_array [
            '/path/to/repo:/repo',
            'rascal-repo-job-builds:/builds'
          ]
        end

        it 'allows to override the repo path' do
          environment = from_config(<<~YAML, 'job')
            .rascal:
              repo_dir: /my-repo

            job:
              image: job-1-image:latest
          YAML

          expect(environment.volumes.first.to_param).to eq '/path/to/repo:/my-repo'
          expect(environment.working_dir).to eq '/my-repo'
        end

        it 'merges config from the .rascal config block' do
          environment = from_config(<<~YAML, 'job')
            .rascal:
              variables:
                rascal-variable: bar
              jobs:
                job:
                  variables:
                    rascal-job-variable: baz


            job:
              image: job-1-image:latest
              variables:
                job-variable: foo
          YAML

          expect(environment.env_variables).to eq(
            'job-variable' => 'foo',
            'rascal-variable' => 'bar',
            'rascal-job-variable' => 'baz',
          )
        end

      end

      describe '#available_environment_names' do

        it 'returns valid jobs' do
          config_path = double(read: <<~YAML, parent: double(to_s: '/path/to/repo', basename: 'repo'))
            .rascal:
              variables:
                rascal-variable: bar

            job-1:
              image: job-1-image:latest

            job-2:
              image: job-1-image:latest

            .hidden-job:
              foo: bar
          YAML

          expect(described_class.new(config_path).available_environment_names).to eq ['job-1', 'job-2']
        end

      end

    end
  end
end
