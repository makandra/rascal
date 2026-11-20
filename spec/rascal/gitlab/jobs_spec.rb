require 'tmpdir'

module Rascal
  module Gitlab
    describe Jobs do

      describe 'config' do

        it 'returns nil for an unknown job' do
          expect(from_config(<<~YAML, 'other-job')).to be_nil
            job:
              image: job-image:latest
          YAML
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

        it 'takes what the job lacks from the default block, including its variables' do
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
          expect(environment.image.name).to eq 'default-image:latest'
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

          expect(environment.image.name).to eq 'global-image:latest'
          expect(environment.services.collect(&:aliases)).to eq [['global-service']]
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

          expect(environment.image.name).to eq 'base-image:latest'
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

          expect(environment.image.name).to eq 'redis-image:latest'
          expect(environment.services.collect(&:aliases)).to eq [['redis']]
        end

        it 'reports templates GitLab would reject as a problem of the job, keeping other jobs usable' do
          jobs = gitlab_jobs(<<~YAML)
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

          expect(jobs.names).to eq ['circular', 'deploy', 'job']
          expect(jobs.environment('circular').problems).to eq ['circular: circular dependency detected in `extends`']
          expect(jobs.environment('deploy').problems).to eq [
            'deploy: unknown keys in `extends` (.deploy-template). Set the missing config in the `.rascal` block ' \
            '(`.rascal: jobs: deploy:`), or hide the job with `hide: true` there.'
          ]
          expect(jobs.environment('job').problems).to eq []
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
          expect(gitlab_jobs(<<~YAML).names).to eq ['job']
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
          expect(from_config(yaml, 'some').image.name).to eq 'default-image:latest'
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

          expect(environment.image.name).to eq 'job-image:latest'
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

          expect(environment.image.name).to eq 'job-image:latest'
          expect(environment.command_containers.entrypoint).to be_nil
        end

        it 'lets the .rascal block override the job' do
          environment = from_config(<<~YAML, 'job')
            .rascal:
              image: rascal-image:latest
            job:
              image: job-image:latest
          YAML

          expect(environment.image.name).to eq 'rascal-image:latest'
        end

        it "lets the .rascal block change only the image's entrypoint, keeping the job's image" do
          environment = from_config(<<~YAML, 'job')
            .rascal:
              jobs:
                job:
                  image:
                    entrypoint: ['']
            job:
              image: registry.example.com/app:$TAG
              variables:
                TAG: '1.2'
          YAML

          expect(environment.image.name).to eq 'registry.example.com/app:1.2'
          expect(environment.command_containers.entrypoint).to eq ['']
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

          expect(environment.image.name).to eq 'rascal-job-image:latest'
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

        it 'removes variables set to null in the .rascal block, like CI for Gemfiles that check ENV.key?' do
          environment = from_config(<<~YAML, 'job')
            .rascal:
              variables:
                CI: null
                GITLAB_CI: ~
            job:
              image: job-image:latest
          YAML

          expect(environment.env_variables.keys).not_to include('CI', 'GITLAB_CI')
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

      end

      describe '#names' do

        it 'lists jobs, but not templates starting with a dot' do
          expect(gitlab_jobs(<<~YAML).names).to eq ['job-1', 'job-2']
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

        it 'does not list default: and stages:' do
          expect(gitlab_jobs(<<~YAML).names).to eq ['job']
            default:
              foo: bar

            stages:
              - a
              - b

            job:
              image: job-1-image:latest
          YAML
        end

        it 'renames a job with name: and hides one with hide: in the .rascal block' do
          jobs = gitlab_jobs(<<~YAML)
            .rascal:
              jobs:
                old-name:
                  name: new-name
                deploy:
                  hide: true
            old-name:
              image: job-image:latest
            deploy:
              image: deploy-image:latest
          YAML

          expect(jobs.names).to eq ['new-name']
          expect(jobs.environment('new-name').image.name).to eq 'job-image:latest'
          expect(jobs.environment('old-name')).to be_nil
        end

        it 'ignores global keywords' do
          expect(gitlab_jobs(<<~YAML).names).to eq ['job']
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
          expect(gitlab_jobs(<<~YAML).names).to eq ['broken', 'job']
            job:
              image: job-image:latest
            broken:
              script: rake
          YAML
        end

        it 'accepts an empty .rascal block' do
          expect(gitlab_jobs(<<~YAML).names).to eq ['job']
            .rascal:
            job:
              image: job-image:latest
          YAML
        end

        it 'treats job names YAML reads as numbers as strings' do
          jobs = gitlab_jobs(<<~YAML)
            .rascal:
              jobs:
                2.6:
                  variables:
                    FOO: bar
            2.6:
              image: job-image:latest
          YAML

          expect(jobs.names).to eq ['2.6']
          expect(jobs.environment('2.6').env_variables).to include('FOO' => 'bar')
        end

        it 'returns nothing for an empty file' do
          expect(gitlab_jobs('').names).to eq []
        end

      end

      describe 'a typical config' do

        let(:typical) do
          gitlab_jobs(File.read(File.expand_path('../../fixtures/typical.gitlab-ci.yml', __dir__)), project: 'app')
        end

        it 'lists the jobs' do
          expect(typical.names).to eq ['checks', 'rspec']
        end

        it 'builds the environment for the test job' do
          environment = typical.environment('rspec')

          expect(environment.image.name).to eq 'registry.example.com/app/test-env:1.2.3'
          expect(environment.env_variables).to include(
            'CI' => 'true',
            'GITLAB_CI' => 'true',
            'RAILS_ENV' => 'test',
            'BUNDLE_PATH' => './tmp/cache/bundle',
            'COREPACK_HOME' => '/repo/tmp/cache/corepack',
            'REDIS_HOST' => 'redis',
          )
          expect(environment.services.collect { |s| [s.aliases.first, s.image.name] }).to eq [
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
