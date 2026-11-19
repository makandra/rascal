<p>
  <a href="https://makandra.de/">
    <picture>
      <source media="(prefers-color-scheme: light)" srcset="media/makandra-with-bottom-margin.light.svg">
      <source media="(prefers-color-scheme: dark)" srcset="media/makandra-with-bottom-margin.dark.svg">
      <img align="right" width="25%" alt="makandra" src="media/makandra-with-bottom-margin.light.svg">
    </picture>
  </a>

  <picture>
    <source media="(prefers-color-scheme: light)" srcset="media/logo.light.shapes.svg">
    <source media="(prefers-color-scheme: dark)" srcset="media/logo.dark.shapes.svg">
    <img width="145" alt="rascal" role="heading" aria-level="1" src="media/logo.light.shapes.svg">
  </picture>
</p>

[![Tests](https://github.com/makandra/rascal/workflows/Tests/badge.svg)](https://github.com/makandra/rascal/actions)

### Use CI environments locally. Not quite a vagrant.

We use Gitlab-CI to run CI for our projects, using Docker containers.

In certain situations, it can be helpful to set up an environment identical to a CI
node on your local machine. `rascal` allows you to do just that by parsing your CI config
(currently only `.gitlab-ci.yml`), starting required services and bringing up a Docker
container.

## Installation

Install with

    $ gem install rascal


## Caveats

*This is an early alpha version. Use at your own risk.*

Only the parsing of `.gitlab-ci.yml` is currently supported, and only a subset of the possible syntax
will be properly interpreted. See [What rascal reads from .gitlab-ci.yml](#what-rascal-reads-from-gitlab-ciyml).


## Usage

You need to add some extra information to your `.gitlab-ci.yml`. A working version might look like this:

```
# settings here override job settings
.rascal:                                 # add rascal specific config here
  repo_dir: /repo                        # /repo is the default
  variables:                             # extra env variables
    BUNDLE_PATH: /cache/bundle
  volumes:                               # mount these volumes
    cache: /cache                        # we will always mount a /builds volume
  before_shell:
    - bundle check                       # run this when starting a shell
  jobs:
    rspec:                               # override settings for a specific job
      variables:
        BUNDLE_GEMFILE = /repo/Gemfile

.environment: &environment
  image: registry.makandra.de/makandra/ci-images/test-env:2.5
  services:
    - name: registry.makandra.de/makandra/ci-images/pg:9.5
      alias: pg-db
    - name: registry.makandra.de/makandra/ci-images/redis:4
      alias: redis
  before_script:
    - ruby -v
    - bundle install
    - bundle exec rake db:create db:schema:load
  variables:
    BUNDLE_PATH: ./bundle/vendor
    DATABASE_URL: postgresql://pg_user@pg-db/test-db
    REDIS_URL: redis://redis
    PROMPT: CI env
  cache:
    paths:
      - ./bundle/vendor


# ============= Actual jobs ================

rspec:
  <<: *environment
  script:
    - bundle exec rake knapsack:rspec
  parallel: 4
```

Then, in your project root, run `rascal shell rspec`.


### What rascal reads from .gitlab-ci.yml

Every top-level key is a job, except for GitLab's global keywords (`default`, `include`, `stages`,
`variables`, `workflow`, and the deprecated `image`, `services`, `cache`, `before_script` and
`after_script`) and keys starting with a dot.

For each job, rascal combines its config like GitLab does, then applies the `.rascal` block on top:

1. `default:` (and the deprecated top-level keys), limited by the job's `inherit: default:`
2. the templates in the job's `extends:`, merged in order
3. the job itself. Each key from steps 2 and 3 replaces the same key from `default:` as a whole.
4. the `.rascal` block
5. the job's entry under `.rascal: jobs:`

From the combined config, rascal uses `image`, `services` and `variables`. It ignores `script`,
`before_script`, `cache`, `rules` and everything else that only matters to a GitLab runner. Use
`before_shell` in the `.rascal` block to prepare the environment instead.

rascal reads local files from `include:`, including wildcards and nested includes, and resolves
`!reference` tags in the keys it uses. It cannot read includes from other projects, URLs, templates or
components, and it cannot evaluate `rules:` on includes, so it includes local files regardless (or
skips them if they are missing). If a job misses config because of that, rascal says so, and you can
add the missing config in the `.rascal` block. A file may start with a header document with `spec:`,
but rascal does not interpolate `$[[ inputs ]]`.

Services may be given as a plain image name (`- postgres:15`). Without an `alias`, a service is
reachable under the host names GitLab derives from its image, like `postgres`.

Variables are resolved like in a GitLab job:

- Global `variables:` (limited by the job's `inherit: variables:`) and job variables are merged by
  name. The `.rascal` block and its `jobs:` entries override them.
- Values, image names and service names may reference variables as `$NAME`, `${NAME}` or `%NAME%`.
  `$$` stands for a literal `$`. A variable defined as `{ value: ..., expand: false }` is used as is.
- In the `.rascal` block, a variable can extend the job's value by referencing its own name, like
  `RUBYOPT: $RUBYOPT -W:deprecated`.
- rascal predefines `CI=true`, `GITLAB_CI=true`, `CI_JOB_NAME`, `CI_BUILDS_DIR` (`/builds`),
  `CI_PROJECT_DIR` (the path of your project in the container, `/repo` by default) and
  `CI_PROJECT_NAME` (the name of your project directory). Tools may behave differently when `CI` is
  set. For example, `pnpm install` refuses to change the lockfile. Override them in the `.rascal`
  block if needed.
- rascal cannot see variables that GitLab sets, like `CI_REGISTRY_IMAGE`, or that are defined in
  the project's CI/CD settings. Define them under `variables:` in the `.rascal` block if a job needs
  them. An undefined variable in a variable's value becomes an empty string, like in GitLab, and
  rascal warns about it. An undefined variable in an image name keeps rascal from starting the job.


### Commands

#### rascal shell <job>

Start a docker container (plus required services) and open an interactive shell.

Currently requires a "bash" to exist.


#### rascal run <job> -- <command>

Run a single command in a docker container (plus required services), then exit
with the command's exit status.

```sh
rascal run rspec -- bundle exec rspec spec/models/user_spec.rb
```

Unlike `rascal shell`, this allocates no TTY and needs no interaction, so it can
be used from scripts, git hooks, editors and AI agents. Everything after `--` is
passed through as a list of arguments, so arguments may contain spaces (`-n 'a
test name'`). To use shell syntax such as `&&` or `cd`, wrap it explicitly:

```sh
rascal run rspec -- bash -c 'cd subproject && bundle exec rspec'
```

`before_shell` and `after_shell` still run around the command, but do not affect
the exit status. Note that a failing `before_shell` command (e.g. `bundle check`
in an environment that was never bundled) does not abort the run.

Currently requires a "bash" to exist.


#### rascal environments

Print the names of all available (non-hidden) environments, one per line, so that
scripts can discover them without parsing an error message.


#### rascal clean <job> | --all [--volumes]

Stop and remove all created containers, services, networks for either the given or all jobs.

If `--volumes` is given, also remove all cached volumes.


#### rascal update <job> | --all

Update all images for the given job, or all jobs.


## Working on rascal

You need Ruby and a running Docker daemon. Install the dependencies with `bundle install`.

All tests are RSpec specs, of three kinds:

| Tests | Location | What they cover | Speed |
|---|---|---|---|
| Unit specs | `spec/rascal/` | Parsing CI configs, resolving variables, and other logic. Most tests belong here. | Fast |
| CLI specs | `spec/cli/` | The command line, with a mocked Docker that records which `docker` commands rascal would call. For what real Docker cannot show easily, like `rascal shell` with a TTY or broken networks. | Fast |
| Integration specs | `spec/integration/` | The real `rascal` executable against a real Docker daemon. | About 20 seconds, plus pulling small images on the first run |

Run them like this:

```sh
bundle exec rake                        # everything, like CI does
bundle exec rspec --tag ~integration    # only the fast specs
bundle exec rspec --tag integration     # only the integration specs
```

The integration specs fail with an explanation when Docker is not running. They do not skip, so a
green run always means everything was tested.

Test each behavior once, at the cheapest level that can show it works:

- Parsing and resolving CI configs belongs in unit specs, with one example per variation.
- What rascal does with Docker belongs in integration specs, for key paths and for behavior only
  real Docker can show, like a job reaching its services by their alias, or exit statuses passing
  through. Do not add one for every variation of a CI config.
- CLI specs cover the rest: command line errors and output, and situations that are hard to create
  with real Docker.

Every spec in `spec/integration/` is tagged with `integration: true` automatically.

Each integration spec creates a project directory named `rascal-it-<random>` in the system's temp
directory, and removes it together with its containers, networks and volumes afterwards. If you abort
a run, you can remove leftovers with:

```sh
docker ps --all --filter name=rascal-rascal-it- --quiet | xargs -r docker rm --force
docker network ls --filter name=rascal-rascal-it- --quiet | xargs -r docker network rm
docker volume ls --filter name=rascal-rascal-it- --quiet | xargs -r docker volume rm
```

Containers write files as root, so leftover `rascal-it-*` directories in the temp directory may need
`sudo rm -rf` to remove.


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
