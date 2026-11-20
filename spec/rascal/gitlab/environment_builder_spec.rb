require 'tmpdir'

module Rascal
  module Gitlab
    # These specs build environments through Jobs#environment, since a .gitlab-ci.yml is the
    # most readable way to describe a Job.
    describe EnvironmentBuilder do

      describe 'the environment' do

        it 'needs only a Job and the project directory' do
          job = Job.new('rspec', 'tests', { 'image' => 'ruby:$RUBY' }, [{ 'RUBY' => '3.4' }, {}, { 'EXTRA' => 'yes' }], [], ['A warning'], '')

          environment = described_class.new(job, project_dir: Pathname.new('/projects/my app')).build

          expect(environment).to have_attributes(name: 'tests', problems: [], warnings: ['A warning'])
          expect(environment.image.name).to eq 'ruby:3.4'
          expect(environment.network.prefixed_name).to eq 'rascal-my_app-tests'
          expect(environment.env_variables).to include('RUBY' => '3.4', 'EXTRA' => 'yes', 'CI_JOB_NAME' => 'rspec', 'CI_PROJECT_NAME' => 'my app')
        end

        it 'builds the environment of a job, named after it' do
          environment = from_config(<<~YAML, 'job-1')
            job-1:
              image: job-1-image:latest
            job-2:
              image: job-2-image:latest
          YAML

          expect(environment.name).to eq 'job-1'
          expect(environment.services).to eq []
          expect(environment.image.name).to eq 'job-1-image:latest'
        end

        it 'mounts the project at /repo and keeps /builds in a volume' do
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

        it 'mounts the project at repo_dir, and points CI_PROJECT_DIR there' do
          environment = from_config(<<~YAML, 'job')
            .rascal:
              repo_dir: /my-repo

            job:
              image: job-1-image:latest
          YAML

          expect(environment.volumes.first.to_param).to eq "#{project_dir}:/my-repo"
          expect(environment.working_dir).to eq '/my-repo'
          expect(environment.env_variables).to include('CI_PROJECT_DIR' => '/my-repo')
        end

        it 'replaces characters Docker does not allow in names' do
          environment = gitlab_jobs(<<~YAML, project: 'my app').environment('job')
            job:
              image: job-image:latest
          YAML

          expect(environment.network.prefixed_name).to eq 'rascal-my_app-job'
          expect(environment.env_variables).to include('CI_PROJECT_NAME' => 'my app')
        end

        it 'takes services_timeout in seconds, and reports anything else as a problem' do
          jobs = gitlab_jobs(<<~YAML)
            .rascal:
              services_timeout: '90'
              jobs:
                invalid:
                  services_timeout: soon
            job:
              image: job-image:latest
            invalid:
              image: job-image:latest
          YAML

          expect(jobs.environment('job').services_timeout).to eq 90
          expect(jobs.environment('invalid').problems).to eq ['services_timeout must be a number of seconds, not "soon".']
        end

      end

      describe 'image' do

        it 'accepts the image in its long form' do
          environment = from_config(<<~YAML, 'job')
            job:
              image:
                name: job-image:latest
                entrypoint: ['']
          YAML

          expect(environment.image.name).to eq 'job-image:latest'
        end

        it 'reports a job without an image as a problem' do
          environment = from_config(<<~YAML, 'job')
            job:
              script: rake
          YAML

          expect(environment.problems).to eq ["Job 'job' has no image. Set `image:` in the job, in `default:`, or in the `.rascal` block (`.rascal: jobs: job: image:`)."]
        end

        it 'expands variables in the image' do
          environment = from_config(<<~YAML, 'job')
            variables:
              IMAGE_TAG: '1.2.3'
            job:
              image: registry.example.com/app:$IMAGE_TAG
          YAML

          expect(environment.image.name).to eq 'registry.example.com/app:1.2.3'
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

        it 'uses image variables defined in the .rascal block' do
          environment = from_config(<<~YAML, 'job')
            .rascal:
              variables:
                CI_REGISTRY_IMAGE: registry.example.com/app
            job:
              image: $CI_REGISTRY_IMAGE/test:latest
          YAML

          expect(environment.problems).to eq []
          expect(environment.image.name).to eq 'registry.example.com/app/test:latest'
        end

      end

      describe 'services' do

        it 'starts services with their aliases and command' do
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
          expect(service.image.name).to eq 'service-1-image'
          expect(service.aliases).to eq ['service-1']
          expect(service.command).to eq ['bin/start']
        end

        it "gives services the job's variables and their own, where null means empty" do
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
                  EMPTY:
          YAML

          expect(environment.services.first.env_variables).to include(
            'FOO' => 'overridden foo',
            'BAR' => 'bar',
            'BAZ' => 'baz',
            'EMPTY' => '',
          )
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
          expect(service.image.name).to eq 'postgres:17-alpine'
          expect(service.env_variables).to include('PGDATA' => '/builds/pg')
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

        it 'accepts services given as a plain image name, with the alias GitLab derives from it' do
          environment = from_config(<<~YAML, 'job')
            job:
              image: job-image:latest
              services:
                - postgres:15
                - registry.example.com/group/redis:7@sha256:abc
          YAML

          expect(environment.services.collect { |s| [s.image.name, s.aliases] }).to eq [
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

        it "only takes HEALTHCHECK_TCP_PORT from the service's own variables" do
          environment = from_config(<<~YAML, 'job')
            job:
              image: job-image:latest
              variables:
                HEALTHCHECK_TCP_PORT: '1234'
              services:
                - name: postgres:16
                  alias: db
                - name: mysql:8
                  alias: mysql
                  variables:
                    HEALTHCHECK_TCP_PORT: '3306'
          YAML

          postgres, mysql = environment.services
          allow(postgres.image).to receive(:exposed_tcp_ports).and_return([5432])
          expect(postgres.ports).to eq [5432]
          expect(mysql.ports).to eq [3306]
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

    end
  end
end
