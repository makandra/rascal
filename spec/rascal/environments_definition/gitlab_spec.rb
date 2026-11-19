require 'tmpdir'

module Rascal
  module EnvironmentsDefinition
    describe Gitlab do

      around do |example|
        Dir.mktmpdir do |dir|
          @tmp_dir = Pathname.new(dir)
          example.run
        end
      end

      # Writes the config to a project directory called "repo", or another name.
      def definition(yaml, project: 'repo')
        project_dir = @tmp_dir.join(project)
        project_dir.mkpath
        project_dir.join('.gitlab-ci.yml').write(yaml)
        described_class.new(project_dir.join('.gitlab-ci.yml'))
      end

      def project_dir(project = 'repo')
        @tmp_dir.join(project).to_s
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

        it 'reports a job without an image as a problem' do
          environment = from_config(<<~YAML, 'job')
            job:
              script: rake
          YAML

          expect(environment.problems).to eq ["Job 'job' has no image. Set `image:` in the job, in `default:`, or in the `.rascal` block (`.rascal: jobs: job: image:`)."]
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
          expect(service.aliases).to eq ['service-1']
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
            "#{project_dir}:/repo",
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

          expect(environment.volumes.first.to_param).to eq "#{project_dir}:/my-repo"
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

        it 'extends the .rascal block with a .rascal.yml next to .gitlab-ci.yml' do
          @tmp_dir.join('repo').mkpath
          @tmp_dir.join('repo/.rascal.yml').write(<<~YAML)
            before_shell:
              - bundle install
            variables:
              LOCAL: local
              SHARED: local
            jobs:
              job:
                variables:
                  LOCAL_JOB: local
          YAML

          environment = from_config(<<~YAML, 'job')
            .rascal:
              before_shell:
                - bundle check
              variables:
                SHARED: rascal-block
                BLOCK: rascal-block
            job:
              image: job-image:latest
          YAML

          expect(environment.before_shell).to eq ['bundle install']
          expect(environment.env_variables).to include('LOCAL' => 'local', 'SHARED' => 'local', 'BLOCK' => 'rascal-block', 'LOCAL_JOB' => 'local')
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
          expect(environment.services.collect(&:aliases)).to eq [['global-service']]
        end

        describe 'services' do

          it 'accepts services given as a plain image name, with the alias GitLab derives from it' do
            environment = from_config(<<~YAML, 'job')
              job:
                image: job-image:latest
                services:
                  - postgres:15
                  - registry.example.com/group/redis:7@sha256:abc
            YAML

            expect(environment.services.collect { |s| [s.container.image, s.aliases] }).to eq [
              ['postgres:15', ['postgres']],
              ['registry.example.com/group/redis:7@sha256:abc', ['registry.example.com-group-redis', 'registry.example.com__group__redis']],
            ]
            expect(environment.services.collect(&:name)).to eq ['repo-job_postgres', 'repo-job_registry.example.com-group-redis']
          end

          it 'accepts several aliases, separated by commas or spaces' do
            environment = from_config(<<~YAML, 'job')
              job:
                image: job-image:latest
                services:
                  - name: postgres:15
                    alias: db, postgres pg
            YAML

            expect(environment.services.first.aliases).to eq ['db', 'postgres', 'pg']
            expect(environment.services.first.name).to eq 'repo-job_db'
          end

          it 'drops the registry port from derived aliases' do
            environment = from_config(<<~YAML, 'job')
              job:
                image: job-image:latest
                services:
                  - localhost:5000/group/postgres:15
            YAML

            expect(environment.services.first.aliases).to eq ['localhost-group-postgres', 'localhost__group__postgres']
          end

          it 'derives valid aliases from an image that cannot be resolved, so the service can still be cleaned' do
            environment = from_config(<<~YAML, 'job')
              job:
                image: job-image:latest
                services:
                  - $SERVICE_IMAGE
            YAML

            expect(environment.services.first.name).to eq 'repo-job_SERVICE_IMAGE'
            expect(environment.problems).to match [/The service \$SERVICE_IMAGE of job 'job' uses the undefined variable SERVICE_IMAGE/]
          end

          it 'reports a service without an image as a problem' do
            environment = from_config(<<~YAML, 'job')
              job:
                image: job-image:latest
                services:
                  - alias: db
            YAML

            expect(environment.problems).to eq ["A service of job 'job' has no image. Set `name:` for each service."]
          end

          it 'warns about undefined variables in service variables' do
            environment = from_config(<<~YAML, 'job')
              job:
                image: job-image:latest
                variables:
                  JOB_VARIABLE: $UNDEFINED_IN_JOB
                services:
                  - name: postgres:15
                    alias: db
                    variables:
                      POSTGRES_PASSWORD: $DB_PASSWORD
            YAML

            expect(environment.warnings).to contain_exactly(
              /Variable JOB_VARIABLE references UNDEFINED_IN_JOB/,
              /Variable POSTGRES_PASSWORD references DB_PASSWORD/,
            )
          end

          it 'derives the alias from the image of a service without one' do
            environment = from_config(<<~YAML, 'job')
              job:
                image: job-image:latest
                services:
                  - name: mariadb:10.6
            YAML

            expect(environment.services.first.aliases).to eq ['mariadb']
          end

          it 'accepts an empty services key' do
            environment = from_config(<<~YAML, 'job')
              job:
                image: job-image:latest
                services:
            YAML

            expect(environment.services).to eq []
          end

        end

        describe 'extends' do

          it 'merges the templates a job extends, like GitLab' do
            environment = from_config(<<~YAML, 'job')
              .base:
                image: base-image:latest
                variables:
                  A: base
                  B: base
                services:
                  - name: postgres:15
                    alias: db
              .more:
                extends: .base
                variables:
                  B: more
                  C: more
              job:
                extends: .more
                variables:
                  C: job
            YAML

            expect(environment.container.image).to eq 'base-image:latest'
            expect(environment.services.collect(&:aliases)).to eq [['db']]
            expect(environment.env_variables).to include('A' => 'base', 'B' => 'more', 'C' => 'job')
          end

          it 'applies several templates in order, and replaces lists instead of merging them' do
            environment = from_config(<<~YAML, 'job')
              .postgres:
                services:
                  - name: postgres:15
                    alias: db
              .redis:
                image: redis-image:latest
                services:
                  - name: redis:7
                    alias: redis
              job:
                extends: [.postgres, .redis]
            YAML

            expect(environment.container.image).to eq 'redis-image:latest'
            expect(environment.services.collect(&:aliases)).to eq [['redis']]
          end

          it 'reports templates GitLab would reject as a problem of the job, keeping other jobs usable' do
            definition = definition(<<~YAML)
              .a:
                extends: circular
              circular:
                image: job-image:latest
                extends: .a
              deploy:
                image: job-image:latest
                extends: .deploy-template
              job:
                image: job-image:latest
            YAML

            expect(definition.available_environment_names).to eq ['circular', 'deploy', 'job']
            expect(definition.environment('circular').problems).to eq ['circular: circular dependency detected in `extends`']
            expect(definition.environment('deploy').problems).to eq [
              'deploy: unknown keys in `extends` (.deploy-template). Set the missing config in the `.rascal` block ' \
              '(`.rascal: jobs: deploy:`), or hide the job with `hide: true` there.'
            ]
            expect(definition.environment('job').problems).to eq []
          end

          it 'reports problems of the templates a job extends' do
            environment = from_config(<<~YAML, 'job')
              .template:
                image: job-image:latest
                services: !reference [.missing, services]
              job:
                extends: .template
            YAML

            expect(environment.problems).to eq [
              'job: !reference [.missing, services] could not be found. Set the config in the `.rascal` block ' \
              '(`.rascal: jobs: job:`), or hide the job with `hide: true` there.'
            ]
          end

          it 'points to includes rascal cannot read when config is missing' do
            environment = from_config(<<~YAML, 'job')
              include:
                - project: group/templates
                  file: ci.yml
              job:
                script: rake
            YAML

            expect(environment.problems).to eq [
              "Job 'job' has no image. It may come from an include rascal cannot read (project: group/templates, file: ci.yml), " \
              "since rascal only reads local includes. Set `image:` in the job, in `default:`, or in the `.rascal` block " \
              "(`.rascal: jobs: job: image:`)."
            ]
          end

          it 'reports templates nested too deeply as a problem, like GitLab' do
            templates = (1..12).map { |i| ".t#{i}:\n  extends: .t#{i + 1}\n" }.join
            environment = from_config(<<~YAML, 'job')
              #{templates}.t13:
                image: job-image:latest
              job:
                extends: .t1
            YAML

            expect(environment.problems).to eq ['.t11: nesting too deep in `extends`']
          end

          it 'lets the .rascal block hide a job whose templates cannot be resolved' do
            expect(definition(<<~YAML).available_environment_names).to eq ['job']
              .rascal:
                jobs:
                  deploy:
                    hide: true
              deploy:
                extends: .deploy-template
              job:
                image: job-image:latest
            YAML
          end

        end

        describe '!reference' do

          it 'resolves references, also nested ones, after extends like GitLab' do
            environment = from_config(<<~YAML, 'job')
              .base:
                services:
                  - name: postgres:15
                    alias: db
              .rspec:
                extends: .base
              .variables:
                shared:
                  A: a
                more: !reference [.variables, shared]
              job:
                image: job-image:latest
                services: !reference [.rspec, services]
                variables: !reference [.variables, more]
            YAML

            expect(environment.problems).to eq []
            expect(environment.services.collect(&:aliases)).to eq [['db']]
            expect(environment.env_variables).to include('A' => 'a')
          end

          it 'resolves references in the .rascal block, flattening lists of commands' do
            environment = from_config(<<~YAML, 'job')
              .setup:
                script:
                  - bundle install
                  - bin/rails db:create
              .rascal:
                before_shell:
                  - !reference [.setup, script]
                  - echo ready
              job:
                image: job-image:latest
            YAML

            expect(environment.before_shell).to eq ['bundle install', 'bin/rails db:create', 'echo ready']
          end

          it 'lets a job replace a reference from its template as a whole' do
            environment = from_config(<<~YAML, 'job')
              .vars:
                A: a
              .template:
                variables: !reference [.vars]
                services: !reference [.missing, services]
              job:
                extends: .template
                image: job-image:latest
                variables:
                  B: b
                services:
                  - redis:7
            YAML

            expect(environment.problems).to eq []
            expect(environment.env_variables).to include('B' => 'b')
            expect(environment.env_variables.keys).not_to include('A')
          end

          it 'ignores references in keys rascal does not use, like script' do
            environment = from_config(<<~YAML, 'job')
              include:
                - project: group/templates
                  file: ci.yml
              job:
                image: job-image:latest
                script:
                  - !reference [.shared, script]
                  - rake
            YAML

            expect(environment.problems).to eq []
          end

          it 'reports references in default: for each job' do
            environment = from_config(<<~YAML, 'job')
              default:
                services: !reference [.missing, services]
              job:
                image: job-image:latest
            YAML

            expect(environment.problems).to match [/job: !reference \[\.missing, services\] could not be found/]
          end

          it 'only warns about missing references in variables, which the .rascal block may define' do
            environment = from_config(<<~YAML, 'job')
              .rascal:
                variables:
                  DB: fallback
              variables: !reference [.missing, variables]
              job:
                image: job-image:latest
                variables:
                  DB: !reference [.remote, variables, DB]
            YAML

            expect(environment.problems).to eq []
            expect(environment.warnings).to contain_exactly(/job: !reference \[\.missing, variables\] could not be found/, /job: !reference \[\.remote, variables, DB\] could not be found/)
            expect(environment.env_variables).to include('DB' => 'fallback')
          end

          it 'reports circular references, and references that are not lists' do
            environment = from_config(<<~YAML, 'job')
              .a:
                services: !reference [.b, services]
              .b:
                services: !reference [.a, services]
              job:
                image: !reference .not-a-list
                services: !reference [.a, services]
            YAML

            expect(environment.problems).to contain_exactly(
              'job: !reference needs a list of keys, like `!reference [.template, services]`.',
              'job: !reference [.a, services] references itself, directly or through other references.',
            )
          end

          it 'mentions skipped includes when a reference cannot be found' do
            environment = from_config(<<~YAML, 'job')
              include:
                - project: group/templates
                  file: ci.yml
              job:
                image: job-image:latest
                services: !reference [.shared, services]
            YAML

            expect(environment.problems.first).to include('could not be found. It may come from an include rascal cannot read (project: group/templates, file: ci.yml)')
          end

        end

        describe 'spec: inputs' do

          it 'reports inputs in images as a problem and in variables as a warning, since rascal does not support them' do
            environment = from_config(<<~YAML, 'job')
              job:
                image: ruby:$[[ inputs.ruby ]]
                variables:
                  STAGE: $[[ inputs.stage ]]
            YAML

            expect(environment.problems).to eq ["The image of job 'job' (ruby:$[[ inputs.ruby ]]) uses `spec: inputs:` (`$[[ inputs.name ]]`), which rascal does not support. Set the value in the `.rascal` block."]
            expect(environment.warnings).to eq ['Variable STAGE uses `spec: inputs:` (`$[[ inputs.name ]]`), which rascal does not support. Set the value in the `.rascal` block.']
          end

        end

        describe 'inherit' do

          it 'lets a job skip all or some keys of the default block' do
            yaml = <<~YAML
              default:
                image: default-image:latest
                services:
                  - name: postgres:15
                    alias: db
              none:
                image: job-image:latest
                inherit:
                  default: false
              some:
                inherit:
                  default: [image]
            YAML

            expect(from_config(yaml, 'none').services).to eq []
            expect(from_config(yaml, 'some').container.image).to eq 'default-image:latest'
            expect(from_config(yaml, 'some').services).to eq []
          end

          it 'lets a job skip all or some global variables' do
            yaml = <<~YAML
              variables:
                A: a
                B: b
              none:
                image: job-image:latest
                inherit:
                  variables: false
              some:
                image: job-image:latest
                inherit:
                  variables: [B]
            YAML

            expect(from_config(yaml, 'none').env_variables.keys).not_to include('A', 'B')
            expect(from_config(yaml, 'some').env_variables).to include('B' => 'b')
            expect(from_config(yaml, 'some').env_variables.keys).not_to include('A')
          end

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

            expect(environment.services.collect(&:aliases)).to eq [['job-service']]
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

          it 'reports undefined variables in the image as a problem' do
            environment = from_config(<<~YAML, 'job')
              job:
                image: $CI_REGISTRY_IMAGE/test:latest
            YAML

            expect(environment.problems).to eq [
              "The image of job 'job' ($CI_REGISTRY_IMAGE/test:latest) uses the undefined variable CI_REGISTRY_IMAGE. " \
              "It is probably set by GitLab or in the project's CI/CD settings, which rascal cannot see. " \
              "Define it for rascal under `variables:` in the `.rascal` block."
            ]
          end

          it 'reports undefined variables in service images as a problem' do
            environment = from_config(<<~YAML, 'job')
              job:
                image: job-image:latest
                services:
                  - name: postgres:$PG_VERSION
                    alias: pg
            YAML

            expect(environment.problems).to match [/The service postgres:\$PG_VERSION of job 'job' uses the undefined variable PG_VERSION/]
          end

          it 'uses image variables defined in the .rascal block' do
            environment = from_config(<<~YAML, 'job')
              .rascal:
                variables:
                  CI_REGISTRY_IMAGE: registry.example.com/app
              job:
                image: $CI_REGISTRY_IMAGE/test:latest
            YAML

            expect(environment.problems).to eq []
            expect(environment.container.image).to eq 'registry.example.com/app/test:latest'
          end

          it 'warns about variables that reference undefined variables' do
            environment = from_config(<<~YAML, 'job')
              job:
                image: job-image:latest
                variables:
                  DATABASE_URL: postgres://user:$DB_PASSWORD@db/$DB_NAME
                  OTHER: fine
            YAML

            expect(environment.warnings).to eq [
              "Variable DATABASE_URL references DB_PASSWORD, DB_NAME, which are undefined and expanded to an empty string. " \
              "If the job needs them, define them under `variables:` in the `.rascal` block."
            ]
            expect(environment.env_variables).to include('DATABASE_URL' => 'postgres://user:@db/')
          end

          it 'only warns about undefined variables a value references directly' do
            environment = from_config(<<~YAML, 'job')
              job:
                image: job-image:latest
                variables:
                  A: $B
                  B: $CI_COMMIT_SHA
            YAML

            expect(environment.warnings).to match [/\AVariable B references CI_COMMIT_SHA/]
          end

          it 'does not warn about a variable that references its own name without a lower definition' do
            environment = from_config(<<~YAML, 'job')
              .rascal:
                variables:
                  RUBYOPT: $RUBYOPT -W:deprecated
              job:
                image: job-image:latest
            YAML

            expect(environment.warnings).to eq []
            expect(environment.env_variables).to include('RUBYOPT' => ' -W:deprecated')
          end

          it 'reports variables that reference each other in a circle as a problem' do
            environment = from_config(<<~YAML, 'job')
              .rascal:
                variables:
                  A: $B
                  B: $A
              job:
                image: job-image:latest
            YAML

            expect(environment.problems).to eq ['The variables A -> B -> A reference each other in a circle. GitLab rejects this as well.']
          end

          it 'merges global and job variables by name before expanding them, like the GitLab server' do
            environment = from_config(<<~YAML, 'job')
              variables:
                OPTS: --global
              job:
                image: job-image:latest
                variables:
                  OPTS: $OPTS --job
            YAML

            # The job's definition replaces the global one (Gitlab::Ci::Variables::Helpers.merge_variables),
            # so $OPTS has no lower definition and rascal expands it to an empty string.
            expect(environment.env_variables).to include('OPTS' => ' --job')
          end

          it 'lets the .rascal block extend a job variable by referencing it' do
            environment = from_config(<<~YAML, 'job')
              variables:
                RUBYOPT: -Wglobal
              .rascal:
                variables:
                  RUBYOPT: $RUBYOPT -Wrascal
                jobs:
                  job:
                    variables:
                      RUBYOPT: $RUBYOPT -Wrascal-job
              job:
                image: job-image:latest
                variables:
                  RUBYOPT: -Wjob
            YAML

            expect(environment.env_variables).to include('RUBYOPT' => '-Wjob -Wrascal -Wrascal-job')
          end

          it 'lets the .rascal block replace a job variable defined with expand: false' do
            environment = from_config(<<~YAML, 'job')
              .rascal:
                variables:
                  PATTERN: rascal-$CI_JOB_NAME
              job:
                image: job-image:latest
                variables:
                  PATTERN:
                    value: $raw
                    expand: false
            YAML

            expect(environment.env_variables).to include('PATTERN' => 'rascal-job')
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
              - project: group/templates
                file: ci.yml
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

        it 'accepts an empty .rascal block' do
          expect(definition(<<~YAML).available_environment_names).to eq ['job']
            .rascal:
            job:
              image: job-image:latest
          YAML
        end

        it 'treats job names YAML reads as numbers as strings' do
          definition = definition(<<~YAML)
            .rascal:
              jobs:
                2.6:
                  variables:
                    FOO: bar
            2.6:
              image: job-image:latest
          YAML

          expect(definition.available_environment_names).to eq ['2.6']
          expect(definition.environment('2.6').env_variables).to include('FOO' => 'bar')
        end

        it 'returns nothing for an empty file' do
          expect(definition('').available_environment_names).to eq []
        end

      end

      describe 'a typical config' do

        let(:typical) do
          definition(File.read(File.expand_path('../../fixtures/typical.gitlab-ci.yml', __dir__)), project: 'app')
        end

        it 'lists the jobs' do
          expect(typical.available_environment_names).to eq ['checks', 'rspec']
        end

        it 'builds the environment for the test job' do
          environment = typical.environment('rspec')

          expect(environment.container.image).to eq 'registry.example.com/app/test-env:1.2.3'
          expect(environment.env_variables).to include(
            'CI' => 'true',
            'GITLAB_CI' => 'true',
            'RAILS_ENV' => 'test',
            'BUNDLE_PATH' => './tmp/cache/bundle',
            'COREPACK_HOME' => '/repo/tmp/cache/corepack',
            'REDIS_HOST' => 'redis',
          )
          expect(environment.services.collect { |s| [s.aliases.first, s.container.image] }).to eq [
            ['db', 'postgres:16'],
            ['redis', 'redis:7.0'],
          ]
          expect(environment.services.first.command).to eq ['postgres', '-c', 'fsync=off']
          expect(environment.before_shell).to eq ['bundle check || bundle install', 'bin/rails db:create db:migrate']
          expect(environment.volumes.collect(&:to_param)).to match_array [
            "#{project_dir('app')}:/repo",
            'rascal-app-rspec-builds:/builds',
            'rascal-app-rspec-cache:/cache',
          ]
        end

      end

    end
  end
end
