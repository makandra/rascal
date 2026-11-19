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

rascal gives you a development environment for a project without setting up the project on your
machine. It reads the project's `.gitlab-ci.yml`, starts the services a CI job needs (like
PostgreSQL or Redis) in Docker, and runs your commands in the job's Docker image, with your project
directory mounted.

You need nothing but Docker and rascal. Ruby, Node, databases and gems come from the images the
project already uses in CI, so an old project with Ruby 2.5 works next to a new one with Ruby 4.

```sh
rascal run rspec -- bundle install                                   # set up
rascal run rspec -- bundle exec rspec spec/models/user_spec.rb      # work
rascal clean rspec --volumes                                         # tear down
```

rascal is meant for people and for AI agents alike: `rascal run` needs no terminal, exits with the
command's status, and explains what is wrong when something is missing.


## Contents

- [Installation](#installation)
- [How it works](#how-it-works)
- [Setting up a project](#setting-up-a-project)
- [Working in the environment](#working-in-the-environment)
- [Tearing down](#tearing-down)
- [Commands](#commands)
- [Configuration](#configuration)
- [What rascal reads from .gitlab-ci.yml](#what-rascal-reads-from-gitlab-ciyml)
- [Troubleshooting](#troubleshooting)
- [Working on rascal](#working-on-rascal)


## Installation

```sh
gem install rascal
```

You need:

- Ruby 3 or newer for rascal itself.
- Docker. On macOS, Docker Desktop works.
- Access to the registries of the project's images. For a private registry, log in first with
  `docker login registry.example.com`.

The job's image needs `bash`. Most CI images have it.


## How it works

Every top-level job in `.gitlab-ci.yml`, like `rspec`, becomes an environment of the same name.
`rascal environments` lists them.

When you run a command in an environment, rascal:

1. pulls the job's image and the images of its services, if they are missing;
2. starts the job's services on a Docker network, reachable under their aliases (like `db` or
   `redis`), unless they are running already, and waits until they accept connections;
3. starts a new container from the job's image, with the job's variables, and your project
   directory mounted at `/repo`;
4. runs `before_shell` from the `.rascal` block, then your command, then `after_shell`;
5. gives files the command created in your project back to you, since the container runs as root;
6. removes the container, and exits with your command's status.

The services keep running between commands, so a database you set up once keeps its data. Each
command gets a fresh container, though: changes outside your project directory and outside volumes
are gone afterwards. That includes the container's home directory, so settings like
`bundle config set` must go into the project (`bundle config set --local`) or into variables.

rascal does not run the job's `script`, `before_script` or `cache`. These are written for one-off CI
jobs, so rascal leaves setup to you, or to `before_shell`.


## Setting up a project

### 1. Pick the environment

```console
$ rascal environments
deploy
rspec
```

Pick the job that runs the tests, usually called `rspec`, `test` or similar. Its image has the
project's language versions and tools, and its services are what the tests need.

### 2. Run it once

```console
$ rascal run rspec -- true
Downloading image for myapp-rspec
...
Starting container for myapp-rspec_db
Starting container for myapp-rspec_redis
```

If rascal cannot start the environment, it says why and what to do. See
[Troubleshooting](#troubleshooting).

### 3. Install dependencies and set up the database

Look at the job's `before_script` and `script` in `.gitlab-ci.yml` to see how CI does it, and run
the equivalent steps. For a typical Rails project:

```sh
rascal run rspec -- bundle install
rascal run rspec -- bin/rails db:create db:schema:load
```

Gems stay installed between commands if the job sets `BUNDLE_PATH` to a directory in the project,
as most CI configs do to cache gems. Otherwise, set it in the `.rascal` block (see below).

### 4. Make it repeatable with a .rascal block (optional)

Commands in `before_shell` run before every command, so the environment is always ready, even after
a teardown or when someone else uses it. Add a `.rascal` block to `.gitlab-ci.yml`, which GitLab
ignores:

```yaml
.rascal:
  before_shell:
    - bundle check > /dev/null || bundle install
    - bin/rails db:create db:migrate
```

`before_shell` runs before every command, so keep it fast. The example above takes a few seconds,
mostly to boot Rails.

If you do not want to change the project's CI config, put the same settings into a `.rascal.yml`
next to `.gitlab-ci.yml`, without the `.rascal:` key, and keep it out of Git:

```sh
cat > .rascal.yml <<'YAML'
before_shell:
  - bundle check > /dev/null || bundle install
YAML
echo .rascal.yml >> .git/info/exclude
```

### Settings that need to persist

Each command runs in a new container, so set what the project needs on every command as variables
in the `.rascal` block or `.rascal.yml`:

```yaml
variables:
  BUNDLE_WITHOUT: deploy        # instead of `bundle config set without deploy`
  BUNDLE_PATH: tmp/bundle       # if the job does not keep gems in the project
```

### Private dependencies over SSH

If `bundle install` or `yarn install` fetches private Git repositories over SSH, enable access to
your SSH agent:

```yaml
ssh_agent: true
```

rascal then mounts the agent from `SSH_AUTH_SOCK` and your `~/.ssh/known_hosts` into the container.
**While a command runs, any code in the container can use all keys in the agent**, including
install scripts of dependencies. Consider a separate agent that only holds a key with read access to
your Git server, and point `SSH_AUTH_SOCK` to it when you run rascal:

```sh
eval $(ssh-agent -a /tmp/git-read-agent.sock) && ssh-add ~/.ssh/git_read_key
SSH_AUTH_SOCK=/tmp/git-read-agent.sock rascal run rspec -- bundle install
```

The container needs an SSH client and must run as root (or as your user), since the agent's socket
belongs to you.

### Variables rascal cannot see

GitLab sets variables like `CI_REGISTRY_IMAGE` or `CI_COMMIT_SHA`, and projects can define more in
their CI/CD settings. rascal only knows a few of GitLab's variables (see
[Variables](#variables)). If a job needs others, define them in the `.rascal` block:

```yaml
variables:
  CI_REGISTRY_IMAGE: registry.example.com/group/myapp
```

rascal warns about variables that reference undefined variables, and refuses to start a job whose
image name does.


## Working in the environment

Run any command with `rascal run`. Everything after `--` is passed on as arguments, so arguments
may contain spaces:

```sh
rascal run rspec -- bundle exec rspec spec/models/user_spec.rb
rascal run rspec -- bundle exec rspec spec/models/user_spec.rb:42 --format documentation
rascal run rspec -- bin/rails runner 'puts User.count'
```

To use shell syntax like `&&`, `|` or `cd`, run it through bash:

```sh
rascal run rspec -- bash -c 'bin/rails db:migrate && bundle exec rspec spec/models'
```

`rascal run` exits with the command's exit status, or with 128 plus the signal number if it was
killed, so scripts and agents can rely on it. If you stop rascal, for example with a timeout, it
removes the command's container. Files the command created in the project may then still belong to
root, until the next command gives them back. Its output is the command's output, plus a few lines
from rascal when it downloads images or starts services.

For an interactive shell, like for a Rails console or a debugger, use `rascal shell rspec`. It runs
bash with `before_shell` and `after_shell` around it, just like a command.

Files you edit on your machine are visible in the container immediately. Files the container
creates, like `Gemfile.lock` changes or downloaded gems, belong to you afterwards.

The environment is the one from CI, so tests that need a browser, a display or a particular service
work if they work in CI. Things that only exist on CI runners, like the job's artifacts or caches from
other jobs, do not.


## Tearing down

```console
$ rascal clean rspec --volumes
Stopping container for myapp-rspec_db
Removing container for myapp-rspec_db
Removing volume rascal-myapp-rspec-builds
```

`rascal clean <job>` stops and removes the job's service containers, including their data, and
its Docker network. With `--volumes`, it also removes the job's named volumes, like caches from the
`.rascal` block. `rascal clean --all` does this for every environment of the project.

Files in your project directory stay, like gems installed into it. Remove them like any other file.


## Commands

All commands take the job's name as the environment, and look for `.gitlab-ci.yml` in the current
directory. Use `--config-file PATH` (or `-c PATH`) to point to another file or directory.

| Command | What it does |
|---|---|
| `rascal run <job> -- <command> [args...]` | Runs a command, without a terminal, and exits with its status. |
| `rascal shell <job>` | Opens an interactive bash. |
| `rascal environments` | Lists the jobs rascal can start environments for, one per line. |
| `rascal clean <job> [--volumes]` | Stops and removes the job's services and network, and with `--volumes` its volumes. |
| `rascal clean --all [--volumes]` | The same for all environments of the project. |
| `rascal update <job>` | Pulls the latest versions of the job's images. |
| `rascal update --all` | The same for all environments. Skips jobs whose images rascal cannot resolve. |
| `rascal --version` | Prints rascal's version. |

Docker resources are named after the project directory and the job, like `rascal-myapp-rspec` for
the network and `rascal-myapp-rspec_db` for a service. Two checkouts of the same project in
directories with different names get separate environments.


## Configuration

rascal takes its settings from the `.rascal` block in `.gitlab-ci.yml`, and from a `.rascal.yml`
next to it, which overrides the block. Both use the same keys:

```yaml
.rascal:
  # Commands to run before and after every command, and around `rascal shell`.
  before_shell:
    - bundle check > /dev/null || bundle install
  after_shell: []

  # Variables for all jobs. They override the jobs' variables, and may reference them:
  # RUBYOPT: $RUBYOPT -W:deprecated extends the job's RUBYOPT.
  variables:
    BUNDLE_WITHOUT: deploy

  # Named Docker volumes for all jobs, as name: path in the container. They keep their
  # content between commands, until `rascal clean --volumes`.
  volumes:
    cache: /cache

  # Where the project directory appears in the container. Default: /repo
  repo_dir: /repo

  # Give the container access to your SSH agent. Default: false
  ssh_agent: false

  # How many seconds to wait for services to accept connections. Default: 30
  services_timeout: 30

  # Settings for single jobs. Besides the keys above, you can override any
  # key of the job, like `image` or `services`.
  jobs:
    rspec:
      variables:
        PARALLEL_TEST_PROCESSORS: '2'
    deploy:
      hide: true          # do not list the job as an environment
    old-name:
      name: new-name      # use another name for the environment
```

Keys in the `.rascal` block replace the job's keys of the same name. Hashes, like `variables`, are merged.


## What rascal reads from .gitlab-ci.yml

Every top-level key is a job, except for GitLab's global keywords (`default`, `include`, `stages`,
`variables`, `workflow`, and the deprecated `image`, `services`, `cache`, `before_script` and
`after_script`) and keys starting with a dot.

For each job, rascal combines its config like GitLab does, then applies the `.rascal` block on top:

1. `default:` (and the deprecated top-level keys), limited by the job's `inherit: default:`
2. the templates in the job's `extends:`, merged in order
3. the job itself. Each key from steps 2 and 3 replaces the same key from `default:` as a whole.
4. the `.rascal` block, extended by `.rascal.yml`
5. the job's entry under `jobs:` in the `.rascal` block or `.rascal.yml`

From the combined config, rascal uses `image`, `services` and `variables`, and ignores everything
else.

rascal reads local files from `include:`, including wildcards and nested includes, and resolves
`!reference` tags in the keys it uses. It cannot read includes from other projects, URLs, templates or
components, and it cannot evaluate `rules:` on includes, so it includes local files regardless (or
skips them if they are missing). If a job misses config because of that, rascal says so, and you can
add the missing config in the `.rascal` block. A file may start with a header document with `spec:`,
but rascal does not interpolate `$[[ inputs ]]`.

### Services

Services may be given as a plain image name (`- postgres:16`) or with `name:`, `alias:` (one or
more, separated by commas or spaces), `command:` and `variables:`. Without an `alias`, a service is
reachable under the host names GitLab derives from its image, like `postgres` for `postgres:16`.

After starting services, rascal waits until each accepts connections on one of the TCP ports its
image exposes, or on `HEALTHCHECK_TCP_PORT` from the service's variables, for up to
`services_timeout` seconds. Then it runs the command anyway.

### Variables

Variables are resolved like in a GitLab job:

- Global `variables:` (limited by the job's `inherit: variables:`) and job variables are merged by
  name. The `.rascal` block and its `jobs:` entries override them, and may extend them by
  referencing their own name.
- Values, image names and service names may reference variables as `$NAME`, `${NAME}` or `%NAME%`.
  `$$` stands for a literal `$`. A variable defined as `{ value: ..., expand: false }` is used as is.
- rascal predefines `CI=true`, `GITLAB_CI=true`, `CI_JOB_NAME`, `CI_BUILDS_DIR` (`/builds`),
  `CI_PROJECT_DIR` (`/repo`, or your `repo_dir`) and `CI_PROJECT_NAME` (the name of your project
  directory). Tools may behave differently when `CI` is set. For example, `pnpm install` refuses to
  change the lockfile. Override them in the `.rascal` block if needed.
- An undefined variable in a variable's value becomes an empty string, like in GitLab, and rascal
  warns about it. An undefined variable in an image name keeps rascal from starting the job.


## Troubleshooting

rascal explains most problems itself. These are the common ones:

#### `Could not find a .gitlab-ci.yml in ...`

Run rascal in the project's root directory, or pass `--config-file`.

#### `Unknown environment ... Available: ...`

Use one of the listed job names. Jobs starting with a dot are templates, not environments.

#### `Job '...' has no image.`

The job gets its image from somewhere rascal cannot see, often an include from another project.
Set it in the `.rascal` block: `jobs: <job>: image: ...`.

#### `The image of job '...' uses the undefined variable ...`

Define the variable under `variables:` in the `.rascal` block, or set the job's image there.

#### `... unknown keys in extends` or `!reference ... could not be found`

The template comes from a file rascal cannot read. Set the config the job needs in the `.rascal`
block, or hide the job with `jobs: <job>: hide: true` if you do not need it.

#### `... uses spec: inputs`

rascal does not interpolate `$[[ inputs.name ]]`. Set the value in the `.rascal` block.

#### `Warning: Variable ... references ..., which is undefined`

Harmless if the command does not need the variable. Otherwise define it in the `.rascal` block.

#### `Docker may need credentials for ...`

Run the `docker login` command from the message.

#### `Cannot connect to the Docker daemon`

Start Docker.

#### Gems or packages are missing after they were installed

They were installed outside the project directory, in the container that is gone now. Set
`BUNDLE_PATH` (or the equivalent for your package manager) to a directory in the project, as a
variable in the `.rascal` block. The same goes for settings made with `bundle config set` without
`--local`.

#### `rascal: Service ... does not accept connections ... continuing anyway`

The service needs longer to start, or listens on a port its image does not declare. Set
`services_timeout` in the `.rascal` block, or `HEALTHCHECK_TCP_PORT` in the service's variables.

#### `Host key verification failed` or `Permission denied (publickey)` when fetching dependencies

Enable `ssh_agent: true`, and make sure your agent holds a key for the Git server (`ssh-add -l`)
and that `~/.ssh/known_hosts` knows the server.

#### `bash: not found` or `executable file not found`

The job's image has no bash. rascal cannot use it. Use another job, or set another image for the
job in the `.rascal` block.

#### The database or other service state is broken

Run `rascal clean <job>` to remove the services and their data. The next command starts them
fresh.

#### Containers or volumes left over from a project directory you deleted

Find them with `docker ps --all --filter name=rascal-` and `docker volume ls --filter name=rascal-`,
and remove them with `docker rm --force` and `docker volume rm`.



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

If a run was aborted while a container was writing files, a leftover `rascal-it-*` directory in the
temp directory may contain files owned by root, which need `sudo rm -rf` to remove.


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
