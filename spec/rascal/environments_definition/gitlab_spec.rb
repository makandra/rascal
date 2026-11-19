module Rascal
  module EnvironmentsDefinition
    describe Gitlab do

      def definition(yaml)
        config_path = double(read: yaml, parent: double(to_s: '/path/to/repo', basename: 'repo'))
        described_class.new(config_path)
      end

      def from_config(yaml, name)
        definition(yaml).environment(name)
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

        it 'returns nil for an unknown job' do
          expect(from_config(<<~YAML, 'other-job')).to be_nil
            job:
              image: job-image:latest
          YAML
        end

        it 'accepts the image in its long form' do
          environment = from_config(<<~YAML, 'job')
            job:
              image:
                name: job-image:latest
                entrypoint: ['']
          YAML

          expect(environment.container.image).to eq 'job-image:latest'
        end

        it 'complains about a job without an image' do
          expect { from_config(<<~YAML, 'job') }.to raise_error(Rascal::Error, "Job 'job' has no image. Set `image:` in the job, in `default:`, or in the `.rascal` block.")
            job:
              script: rake
          YAML
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

          expect(environment.env_variables).to include(
            'FOO' => 'foo',
            'BAR' => 'bar',
          )
        end

        it 'sets env variables for services' do
          environment = from_config(<<~YAML, 'job')
          job:
            image: job-1-image:latest
            variables:
              FOO: foo
              BAR: bar
            services:
              - name: service-1-image
                alias: service-1
                command: bin/start
                variables:
                  FOO: overridden foo
                  BAZ: baz
          YAML

          expect(environment.services.first.env_variables).to include(
            'FOO' => 'overridden foo',
            'BAR' => 'bar',
            'BAZ' => 'baz',
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

          expect(environment.env_variables).to include(
            'job-variable' => 'foo',
            'rascal-variable' => 'bar',
            'rascal-job-variable' => 'baz',
          )
        end

        it 'merges config from a default block' do
          environment = from_config(<<~YAML, 'job-1')
            default:
              image: default-image:latest
              variables:
                foo-variable: foo

            job-1:
              variables:
                bar-variable: bar
          YAML

          expect(environment.name).to eq 'job-1'
          expect(environment.container.image).to eq 'default-image:latest'
          expect(environment.env_variables).to include(
            'foo-variable' => 'foo',
            'bar-variable' => 'bar',
          )
        end

        it 'treats deprecated top-level keys like the default block' do
          environment = from_config(<<~YAML, 'job')
            image: global-image:latest
            services:
              - name: global-service-image
                alias: global-service

            job:
              script: rake
          YAML

          expect(environment.container.image).to eq 'global-image:latest'
          expect(environment.services.collect(&:alias)).to eq ['global-service']
        end

        describe 'precedence' do

          it 'lets the job override the default block, like GitLab does' do
            environment = from_config(<<~YAML, 'job')
              default:
                image: default-image:latest
              job:
                image: job-image:latest
            YAML

            expect(environment.container.image).to eq 'job-image:latest'
          end

          it 'lets the job replace the services of the default block' do
            environment = from_config(<<~YAML, 'job')
              default:
                image: default-image:latest
                services:
                  - name: default-service-image
                    alias: default-service
              job:
                services:
                  - name: job-service-image
                    alias: job-service
            YAML

            expect(environment.services.collect(&:alias)).to eq ['job-service']
          end

          it 'lets a job key replace the same key in the default block as a whole' do
            environment = from_config(<<~YAML, 'job')
              default:
                image:
                  name: default-image:latest
                  entrypoint: ['']
              job:
                image:
                  name: job-image:latest
            YAML

            expect(environment.container.image).to eq 'job-image:latest'
            expect(definition(<<~YAML).send(:jobs).first.config.get('image')).to eq('name' => 'job-image:latest')
              default:
                image:
                  name: default-image:latest
                  entrypoint: ['']
              job:
                image:
                  name: job-image:latest
            YAML
          end

          it 'lets the .rascal block override the job' do
            environment = from_config(<<~YAML, 'job')
              .rascal:
                image: rascal-image:latest
              job:
                image: job-image:latest
            YAML

            expect(environment.container.image).to eq 'rascal-image:latest'
          end

          it 'lets .rascal job config override the .rascal block' do
            environment = from_config(<<~YAML, 'job')
              .rascal:
                image: rascal-image:latest
                jobs:
                  job:
                    image: rascal-job-image:latest
              job:
                image: job-image:latest
            YAML

            expect(environment.container.image).to eq 'rascal-job-image:latest'
          end

          it 'orders variables from global over job to .rascal' do
            environment = from_config(<<~YAML, 'job')
              variables:
                GLOBAL: global
                JOB: global
                RASCAL: global
              .rascal:
                variables:
                  RASCAL: rascal
              job:
                image: job-image:latest
                variables:
                  JOB: job
                  RASCAL: job
            YAML

            expect(environment.env_variables).to include(
              'GLOBAL' => 'global',
              'JOB' => 'job',
              'RASCAL' => 'rascal',
            )
          end

        end

        describe 'variables' do

          it 'sets a subset of the variables GitLab predefines' do
            environment = from_config(<<~YAML, 'job')
              job:
                image: job-image:latest
            YAML

            expect(environment.env_variables).to eq(
              'CI' => 'true',
              'GITLAB_CI' => 'true',
              'CI_JOB_NAME' => 'job',
              'CI_PROJECT_NAME' => 'repo',
              'CI_PROJECT_DIR' => '/repo',
              'CI_BUILDS_DIR' => '/builds',
            )
          end

          it 'points CI_PROJECT_DIR to a changed repo_dir' do
            environment = from_config(<<~YAML, 'job')
              .rascal:
                repo_dir: /my-repo
              job:
                image: job-image:latest
            YAML

            expect(environment.env_variables).to include('CI_PROJECT_DIR' => '/my-repo')
          end

          it 'allows to override predefined variables' do
            environment = from_config(<<~YAML, 'job')
              .rascal:
                variables:
                  CI: 'false'
              job:
                image: job-image:latest
            YAML

            expect(environment.env_variables).to include('CI' => 'false')
          end

          it 'converts values to strings' do
            environment = from_config(<<~YAML, 'job')
              job:
                image: job-image:latest
                variables:
                  BOOLEAN: true
                  NUMBER: 3
                  EMPTY:
            YAML

            expect(environment.env_variables).to include(
              'BOOLEAN' => 'true',
              'NUMBER' => '3',
              'EMPTY' => '',
            )
          end

          it 'expands references to other variables' do
            environment = from_config(<<~YAML, 'job')
              variables:
                CACHE_DIR: $CI_PROJECT_DIR/tmp/cache
              job:
                image: job-image:latest
                variables:
                  BUNDLE_PATH: ${CACHE_DIR}/bundle
            YAML

            expect(environment.env_variables).to include(
              'CACHE_DIR' => '/repo/tmp/cache',
              'BUNDLE_PATH' => '/repo/tmp/cache/bundle',
            )
          end

          it 'expands variables in the image' do
            environment = from_config(<<~YAML, 'job')
              variables:
                IMAGE_TAG: '1.2.3'
              job:
                image: registry.example.com/app:$IMAGE_TAG
            YAML

            expect(environment.container.image).to eq 'registry.example.com/app:1.2.3'
          end

          it 'expands variables in service images, including service variables' do
            environment = from_config(<<~YAML, 'job')
              variables:
                PG_VERSION: '17'
              job:
                image: job-image:latest
                services:
                  - name: postgres:$PG_VERSION-$FLAVOR
                    alias: pg
                    variables:
                      FLAVOR: alpine
                      PGDATA: $CI_BUILDS_DIR/pg
            YAML

            service = environment.services.first
            expect(service.container.image).to eq 'postgres:17-alpine'
            expect(service.env_variables).to include('PGDATA' => '/builds/pg')
          end

          it 'complains about undefined variables in the image' do
            expect { from_config(<<~YAML, 'job') }.to raise_error(Rascal::Error, "The image of job 'job' (app:$IMAGE_TAG) uses the undefined variable IMAGE_TAG. Define IMAGE_TAG under `variables:`, or set the image in the `.rascal` block.")
              job:
                image: app:$IMAGE_TAG
            YAML
          end

          it 'complains about undefined variables in service images' do
            expect { from_config(<<~YAML, 'job') }.to raise_error(Rascal::Error, /The service postgres:\$PG_VERSION of job 'job' uses the undefined variable PG_VERSION/)
              job:
                image: job-image:latest
                services:
                  - name: postgres:$PG_VERSION
                    alias: pg
            YAML
          end

        end

      end

      describe '#available_environment_names' do

        it 'returns valid jobs' do
          expect(definition(<<~YAML).available_environment_names).to eq ['job-1', 'job-2']
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
        end

        it 'ignores special keys' do
          expect(definition(<<~YAML).available_environment_names).to eq ['job']
            default:
              foo: bar

            stages:
              - a
              - b

            job:
              image: job-1-image:latest
          YAML
        end

        it 'ignores global keywords' do
          expect(definition(<<~YAML).available_environment_names).to eq ['job']
            variables:
              IMAGE_TAG: '1'
            workflow:
              rules:
                - if: $CI_COMMIT_BRANCH
            include:
              - local: ci/other.yml
            image: global-image:latest
            services:
              - name: global-service-image
                alias: global-service
            cache:
              paths: [tmp/cache]
            before_script:
              - ruby -v
            after_script:
              - echo done

            job:
              script: rake
          YAML
        end

        it 'lists jobs without an image, which fail only when used' do
          expect(definition(<<~YAML).available_environment_names).to eq ['broken', 'job']
            job:
              image: job-image:latest
            broken:
              script: rake
          YAML
        end

        it 'returns nothing for an empty file' do
          expect(definition('').available_environment_names).to eq []
        end

      end

      describe 'a typical config' do

        let(:definition) do
          config_path = double(read: File.read(File.expand_path('../../fixtures/typical.gitlab-ci.yml', __dir__)), parent: double(to_s: '/path/to/app', basename: 'app'))
          described_class.new(config_path)
        end

        it 'lists the jobs' do
          expect(definition.available_environment_names).to eq ['checks', 'rspec']
        end

        it 'builds the environment for the test job' do
          environment = definition.environment('rspec')

          expect(environment.container.image).to eq 'registry.example.com/app/test-env:1.2.3'
          expect(environment.env_variables).to include(
            'CI' => 'true',
            'GITLAB_CI' => 'true',
            'RAILS_ENV' => 'test',
            'BUNDLE_PATH' => './tmp/cache/bundle',
            'COREPACK_HOME' => '/repo/tmp/cache/corepack',
            'REDIS_HOST' => 'redis',
          )
          expect(environment.services.collect { |s| [s.alias, s.container.image] }).to eq [
            ['postgresql', 'postgres:17.5'],
            ['redis', 'redis:7.0'],
          ]
          expect(environment.services.first.command).to eq ['postgres', '-c', 'fsync=off']
          expect(environment.before_shell).to eq ['bundle check || bundle install', 'bin/rails db:create db:migrate']
          expect(environment.volumes.collect(&:to_param)).to match_array [
            '/path/to/app:/repo',
            'rascal-app-rspec-builds:/builds',
            'rascal-app-rspec-cache:/cache',
          ]
        end

      end

    end
  end
end
