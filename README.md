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
rascal clean --all --volumes                                         # tear down
```

rascal is meant for people and for AI agents alike: `rascal run` needs no terminal, keeps the
command's output separate from its own, exits with the command's status, and explains what is wrong
when something is missing.


## Contents

- [Installation](#installation)
- [How it works](#how-it-works)
- [Setting up a project](#setting-up-a-project)
- [Working in the environment](#working-in-the-environment)
- [Common adjustments](#common-adjustments)
- [Tearing down](#tearing-down)
- [Commands](#commands)
- [Configuration](#configuration)
- [What rascal reads from .gitlab-ci.yml](#what-rascal-reads-from-gitlab-ciyml)
- [Troubleshooting](#troubleshooting)
- [Working on rascal](#working-on-rascal)


## Installation

Install rascal with a Ruby of your own, not into the project's bundle. rascal needs neither the
project's Ruby nor its gems, so one installation works for all projects, old and new. It needs
Ruby 3.0 or newer.

Ruby version managers like mise or rbenv switch to the project's Ruby inside a project directory
(from `.ruby-version`), and that Ruby usually does not have rascal. So pick one Ruby for rascal, and
use it to install and to run rascal:

```sh
# With mise
mise exec ruby@4.0.9 -- gem install rascal
mise exec ruby@4.0.9 -- rascal run rspec -- bundle install

# With rbenv
RBENV_VERSION=4.0.9 gem install rascal
RBENV_VERSION=4.0.9 rascal run rspec -- bundle install

# Without a version manager
gem install rascal
rascal run rspec -- bundle install
```

The examples below just say `rascal`. If rascal is already installed, mise and rbenv name the Ruby
that has it when you run `rascal` in a project whose Ruby does not. Check the version with
`rascal --version`. Each installed version comes with its own copy of this README, which
`rascal help` names.

You also need:

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
   `redis`), unless they are running already. It waits until each service that is still starting
   accepts connections on one of its ports;
3. starts a new container from the job's image, with the job's variables, and your project
   directory mounted at `/repo`;
4. runs a bash script in it: the `before_shell` commands from the `.rascal` block, your command,
   then the `after_shell` commands;
5. gives files in your project that belong to root back to you, since the container usually runs
   as root;
6. removes the container, and exits with your command's status.

**What stays between commands:** the services keep running, so a database you set up once keeps
its data. Files in your project directory and in volumes stay too. Everything else in the job's
container is gone after each command, including its home directory. So settings like
`bundle config set` must go into the project (`bundle config set --local`) or into variables, see
[Settings that need to persist](#settings-that-need-to-persist).

**Services are reused as they are.** If you change a service's settings, or pull newer images with
`rascal update`, run `rascal clean <job>` so the next command starts the services anew.

rascal does not run the job's `script`, `before_script` or `cache`. These are written for one-off CI
jobs, so rascal leaves setup to you, or to `before_shell`.

**rascal names its Docker resources after the project directory's name**, not its path. Two checkouts
with the same directory name share their environment, including databases, and `rascal clean` in one
removes the other's. Give each checkout its own directory name, like `myapp-feature-x`. Prefer clones
over Git worktrees: Git commands in the container cannot see a worktree's repository.


## Setting up a project

### 1. Pick the environment

```console
$ rascal environments
deploy
rspec
```

Pick the job that runs the tests, usually called `rspec`, `test` or similar. Its image has the
project's language versions and tools, and its services are what the tests need. The list includes
jobs rascal cannot start, like deploy jobs.

### 2. Look at the environment

`rascal status` shows what rascal made of the job's config, without starting or downloading
anything:

```console
$ rascal status rspec
rspec
  Image:      registry.example.com/myapp/test:2.0 (not downloaded, the next command downloads it)
  Network:    rascal-myapp-rspec (does not exist)
  Services:
    db: postgres:16 (not downloaded), not created, the next command starts it
    redis: redis:7 (not downloaded), not created, the next command starts it
  Volumes:
    /repo: /home/me/myapp
    /builds: volume rascal-myapp-rspec-builds (does not exist)
  Variables:
    BUNDLE_PATH=tmp/cache/bundle
    CI=true
    ...
  before_shell:
    bundle check > /dev/null || bundle install
  ssh_agent: false, services_timeout: 30
```

Check three things before you go on:

- **Problems** keep the environment from starting. Each says what to do, see also
  [Troubleshooting](#troubleshooting).
- **`before_shell`** runs before each of your commands. The project's `.rascal` block may already
  install dependencies there.
- **`BUNDLE_PATH`** keeps gems in the project, so they stay installed between commands. Most CI
  configs set it. If it is missing, see [Settings that need to persist](#settings-that-need-to-persist)
  before you install gems.

Later, `rascal status` also shows whether each service runs or how it exited, with the command to see
its logs. With `--json`, it prints the same as JSON.

### 3. Run it once

```console
$ rascal run rspec -- true
Downloading image for myapp-rspec
...
Starting container for myapp-rspec_db
Starting container for myapp-rspec_redis
```

The first run downloads the images, which can take several minutes. If you run rascal with a
timeout, give this run a generous one.

### 4. Install dependencies and set up the database

Look at the job's `before_script` and `script` in `.gitlab-ci.yml` to see how CI does it, and run
the equivalent steps. For a typical Rails project:

```sh
rascal run rspec -- bundle install
rascal run rspec -- bin/rails db:create db:schema:load
```

Leave out steps that only make sense on a CI runner, like ones that use `CI_JOB_TOKEN` to fetch
private repositories, and fetch private dependencies [over SSH](#private-dependencies-over-ssh)
instead. Steps like `cp config/database.ci.yml config/database.yml` change your project directory.
Run them if the file is missing. If it exists, it may be a local file that Git ignores, so compare
it with the CI version before you replace it.

You only need the steps for what you want to run. A model spec may need only gems and a database,
while browser tests may also need Node packages (`yarn install`) and compiled assets.

**Setup can change files in Git.** For example, `bundle install` may rewrite `Gemfile.lock` if the
Gemfile treats CI differently (rascal sets `CI` and `GITLAB_CI`, see [Variables](#variables)). Check
`git status` after setting up, and undo changes you did not intend before you commit anything.
Some changes come back with every command. If you need to change dependencies, see
[Changing dependencies](#changing-dependencies).

### 5. Make it repeatable (optional)

Commands in `before_shell` run before every command, so the environment is always ready, even after
a teardown or when someone else uses it. Add a `.rascal` block to `.gitlab-ci.yml`, which GitLab
ignores:

```yaml
.rascal:
  before_shell:
    - bundle check > /dev/null || bundle install
    - bin/rails db:create db:migrate
```

All commands run in one bash script, one per line:

- A failing `before_shell` command does not stop your command, and does not change the exit status.
- Its output appears with your command's output on every run. Redirect it, like `> /dev/null`
  above, to keep your command's output clean.
- `cd` or `export` in `before_shell` apply to your command too.
- It runs before every command, so keep it fast. The example above takes a few seconds, mostly to
  boot Rails.

If you do not want to change the project's CI config, put the same settings into a `.rascal.yml`
next to `.gitlab-ci.yml`, without the `.rascal:` key, and keep it out of Git:

```sh
cat > .rascal.yml <<'YAML'
before_shell:
  - bundle check > /dev/null || bundle install
YAML
echo .rascal.yml >> "$(git rev-parse --git-path info/exclude)"
```

`.rascal.yml` overrides the `.rascal` block: its lists, like `before_shell`, replace the block's,
and its hashes, like `variables`, are merged into the block's. Wherever this README says "the
`.rascal` block", `.rascal.yml` works too. In a project you do not maintain, use `.rascal.yml`.


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

What to expect from `rascal run`:

- **Output:** stdout is your command's stdout (plus the output of `before_shell` and `after_shell`).
  rascal's own messages, like `Starting container for ...`, image downloads and warnings, go to
  stderr.
- **Input:** stdin is passed to the command when it comes from a file or a pipe, so
  `rascal run rspec -- psql < dump.sql` works, or from a socket that already has input, as Node's
  `child_process` provides it. A terminal, or a socket without input, is not passed on, so a command
  waiting for input, like a forgotten `debugger` call, gets none instead of hanging. A pipe that
  stays open without input still makes such a command wait.
- **Exit status:** your command's, or 128 plus the signal number if it was killed. If rascal itself
  fails, for example for an unknown job, it exits with 1, like many failing commands, and explains why
  on stderr. If Docker cannot start the container, for example because the image has no bash, the
  status is 125 to 127. 127 is also what bash returns for a command the image does not have.
- **Stopping:** if you stop rascal, for example with a timeout, it removes the command's container.
  Files the command created in the project may then still belong to root, until the next command
  gives them back.
- **Environment variables** from your shell are not passed into the container. Use
  `rascal run rspec --env FOO=bar -- bin/rails runner ...`, or the `.rascal` block to set them for
  every command. `--unset-env NAME` removes one, like `CI`.
- **Parallel commands** in the same environment work, like several test runs at once. Each gets its
  own container, and they share the services, including the test database. Two commands that load
  the schema or run tests at the same time get in each other's way, unless the project's parallel
  test setup gives each its own database.

For an interactive shell, like for a Rails console or a debugger, use `rascal shell rspec`. It runs
bash with `before_shell` and `after_shell` around it, just like a command. It needs a terminal.
Without one, like as an AI agent, debug with commands instead: run single examples, add output to
the code, or use `bin/rails runner` to inspect state.

Files you edit on your machine are visible in the container immediately. Files the container
creates, like `Gemfile.lock` changes or installed gems, belong to you afterwards (on Linux; Docker
Desktop handles this itself).

The container runs the job's image, but not the job's `before_script`, so tools that CI starts or
installs there, like a virtual display for browser tests, are missing unless you start them yourself.
rascal does not publish ports to your machine, so you cannot open a server running in the container
in your browser.

### Changing dependencies

Update dependencies in the container, like you would on your machine:

```sh
rascal run rspec -- bundle update rack --conservative
```

Some Gemfiles leave out gems when `CI` is set, typically private gems that CI cannot fetch. Look
for `ENV['CI']` or `ENV.key?('CI')` in the Gemfile. Since rascal sets `CI` like GitLab does, every
Bundler command, even `bundle exec`, then writes a `Gemfile.lock` without these gems: their `GIT`
block disappears. To change dependencies in such a project, run the change without these variables,
and with your [SSH agent](#private-dependencies-over-ssh) to fetch the private gems:

```sh
git checkout HEAD -- Gemfile.lock   # start from the committed lockfile (commit changes to keep first)
rascal run rspec --unset-env CI --unset-env GITLAB_CI --ssh-agent -- bundle update rack --conservative
git add Gemfile.lock                # keep this version
git diff --cached Gemfile.lock
```

The diff should only show the changes you intended. Run tests as usual, with `CI` set, since
projects often check it elsewhere too, like for eager loading. Each Bundler command removes the
private gems from `Gemfile.lock` again, so before you commit, restore the version you staged with
`git checkout Gemfile.lock`.


## Common adjustments

Settings for the `.rascal` block or `.rascal.yml` that many projects need. See
[Configuration](#configuration) for all of them.

### Settings that need to persist

Each command runs in a new container, which is gone afterwards with everything outside the project
directory and volumes: gems installed elsewhere, and settings made with `bundle config set` (without
`--local`). So set what the project needs on every command as variables in the `.rascal` block:

```yaml
variables:
  BUNDLE_WITHOUT: deploy        # instead of `bundle config set without deploy`
  BUNDLE_PATH: tmp/bundle       # if the job does not keep gems in the project
```

To keep gems out of the project directory, use a volume instead:

```yaml
volumes:
  gems: /gems
variables:
  BUNDLE_PATH: /gems
```

### Private dependencies over SSH

If `bundle install` or `yarn install` fetches private Git repositories over SSH, give the commands
that need it access to your SSH agent:

```sh
rascal run rspec --ssh-agent -- bundle install
```

rascal then mounts your SSH agent and your `~/.ssh/known_hosts` into the container. It does not
mount `~/.ssh/config`, so host aliases from there do not work. To give the agent to every command,
set `ssh_agent: true` in the `.rascal` block. `--no-ssh-agent` keeps it from a single command.

**While a command runs, any code in the container can use all keys in the agent**, including
install scripts of dependencies. So give it only to the commands that need it. With Docker Engine on
Linux, you can also start a separate agent that only holds a key with read access to your Git
server, and point rascal to it:

```sh
ssh-agent -a /tmp/git-read-agent.sock > /dev/null
SSH_AUTH_SOCK=/tmp/git-read-agent.sock ssh-add ~/.ssh/git_read_key
SSH_AUTH_SOCK=/tmp/git-read-agent.sock rascal run rspec --ssh-agent -- bundle install
```

Docker Desktop (on macOS, and on Linux) always provides the agent of your desktop session, with all
its keys, and ignores `SSH_AUTH_SOCK`.

**If you are an AI agent,** ask your user before you give a command your SSH agent, unless a
separate agent with a limited key is available.

The container needs an SSH client, and must run as root (or as your user), since the agent's socket
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

### An image's entrypoint that gets in the way

rascal runs commands through the image's entrypoint, like CI does. Some images have an entrypoint
made for another setup, like the project's own Docker development setup, which refuses to run as
root or expects volumes that only that setup provides. Skip it for rascal in `.rascal.yml`:

```yaml
jobs:
  rspec:
    image:
      entrypoint: ['']
```

The job keeps its image: an image without a `name` only changes the parts it gives, while one with a
`name` replaces the image as a whole. Once the image is downloaded, `rascal status` shows its entrypoint. To see
what it did, look at it, like `rascal run rspec -- cat /docker-entrypoint.sh`, and do what your
commands need yourself.


## Tearing down

```console
$ rascal clean --all --volumes
Stopping container for myapp-rspec_db
Removing container for myapp-rspec_db
Stopping container for myapp-rspec_redis
Removing container for myapp-rspec_redis
Removing network rascal-myapp-rspec
Removing volume rascal-myapp-rspec-builds
```

`rascal clean <job>` stops and removes the job's service containers, including their data, and the
job's Docker network. With `--volumes`, it also removes the job's named volumes: the volume for
`/builds`, and the volumes from the `.rascal` block. `--all` does this for every environment of the
project.

These stay:

- files in your project directory, like gems installed into it, and your `.rascal.yml`;
- the downloaded images, which other projects may use too. Remove them with `docker image rm`;
- an empty lock file per job in the temp directory, like `/tmp/rascal-myapp-rspec.lock`.

To check that nothing is left, list what Docker has for the project (`myapp` being the name of the
project directory):

```sh
docker ps --all --filter name=rascal-myapp-
docker network ls --filter name=rascal-myapp-
docker volume ls --filter name=rascal-myapp-
```


## Commands

Commands that work on an environment take the job's name. All look for `.gitlab-ci.yml` in the
current directory.

| Command | What it does |
|---|---|
| `rascal run <job> -- <command> [args...]` | Runs a command, without a terminal, and exits with its status. |
| `rascal shell <job>` | Opens an interactive bash. Needs a terminal. |
| `rascal environments` | Lists the project's jobs, one per line, including ones rascal cannot start. |
| `rascal status [<job>] [--json]` | Shows what rascal made of the job's config, and what of it exists in Docker (see [Troubleshooting](#troubleshooting)). Without a job, shows all. |
| `rascal clean <job> [--volumes]` | Stops and removes the job's services and network, and with `--volumes` its volumes. |
| `rascal clean --all [--volumes]` | The same for all environments of the project. |
| `rascal update <job>` | Pulls the latest versions of the job's images. Run `rascal clean <job>` afterwards to restart services with them. |
| `rascal update --all` | The same for all environments. Skips jobs whose images rascal cannot resolve. |
| `rascal --version` | Prints rascal's version. |

Options go before `--`, before or after the job's name.

With `--config-file PATH` (or `-c PATH`), rascal uses another `.gitlab-ci.yml`, or the one in another
directory. The directory of that file counts as the project directory: rascal mounts it, and looks
for `.rascal.yml` and local includes there.

`run` and `shell` take options that change only this command's container. Services keep their
settings.

| Option | What it does |
|---|---|
| `--env NAME=VALUE` | Sets a variable. Repeat it for more. |
| `--unset-env NAME` | Removes a variable, like `CI`. Repeat it for more. |
| `--ssh-agent` | Gives the container your SSH agent, like `ssh_agent: true` (see [Private dependencies over SSH](#private-dependencies-over-ssh)). |

### Docker resources

rascal names everything after the project directory and the job:

| Resource | Name |
|---|---|
| Network | `rascal-myapp-rspec` |
| Service container | `rascal-myapp-rspec_db`, after the service's first alias |
| Container of a command | `rascal-myapp-rspec-run-` and a random suffix, removed after the command |
| Volume for `/builds` | `rascal-myapp-rspec-builds` |
| Volume from the `.rascal` block | `rascal-myapp-rspec-cache`, after its name |

Only the name of the directory counts, not its path (see [How it works](#how-it-works)).


## Configuration

rascal takes its settings from the `.rascal` block in `.gitlab-ci.yml`, and from a `.rascal.yml`
next to it. Both use the same keys:

```yaml
.rascal:
  # Commands to run in the same bash script before and after every command, and around
  # `rascal shell`. Failures do not stop the command.
  before_shell:
    - bundle check > /dev/null || bundle install
  after_shell: []

  # Variables for all jobs. They override the jobs' variables, and may reference them:
  # RUBYOPT: $RUBYOPT -W:deprecated extends the job's RUBYOPT. Only variables from the
  # CI config count, not those the image sets, so do not extend PATH this way.
  variables:
    BUNDLE_WITHOUT: deploy

  # Docker volumes as name: path in the container. Each job gets its own, which keep their
  # content between commands, until `rascal clean --volumes`.
  volumes:
    cache: /cache

  # Where the project directory appears in the container. Default: /repo
  repo_dir: /repo

  # Give the container access to your SSH agent. Default: false
  ssh_agent: false

  # How many seconds to wait for each service to accept connections. Default: 30
  services_timeout: 30

  # Settings for single jobs. Besides the keys above, you can override any key of the job,
  # like `image` or `services`.
  jobs:
    rspec:
      variables:
        PARALLEL_TEST_PROCESSORS: '2'
    deploy:
      hide: true          # do not list the job as an environment
    old-name:
      name: new-name      # use another name for the environment
```

Keys in the `.rascal` block replace the job's keys of the same name, for every job. Hashes, like
`variables`, are merged. Use `jobs:` to change a single job.


## What rascal reads from .gitlab-ci.yml

Every top-level key is a job, except for GitLab's global keywords (`default`, `include`, `stages`,
`variables`, `workflow`, and the deprecated `image`, `services`, `cache`, `before_script` and
`after_script`) and keys starting with a dot.

For each job, rascal combines its config like GitLab does, then applies rascal's settings on top:

1. `default:` (and the deprecated top-level keys), limited by the job's `inherit: default:`
2. the templates in the job's `extends:`, merged in order
3. the job itself. Each key from steps 2 and 3 replaces the same key from `default:` as a whole.
4. the `.rascal` block, overridden by `.rascal.yml`
5. the job's entry under `jobs:` in the `.rascal` block or `.rascal.yml`

From the combined config, rascal uses `image` (its name and `entrypoint`), `services` and
`variables`. It ignores everything else, like `script`, `rules` or `cache`.

rascal reads local files from `include:`, including wildcards and nested includes, and resolves
`!reference` tags. It cannot read includes from other projects, URLs, templates or components, and
warns about them, since config from them is missing. It cannot evaluate `rules:` on includes either,
so it includes local files regardless (or skips them if they are missing). A file may start with a
header document with `spec:`, but rascal does not interpolate `$[[ inputs ]]`.

### Services

Services may be given as a plain image name (`- postgres:16`) or with `name:`, `alias:` (one or
more, separated by commas or spaces), `command:` and `variables:`. Without an `alias`, a service is
reachable under the host names GitLab derives from its image, like `postgres` for `postgres:16`.
Your project directory is mounted into the services too.

After starting services, rascal waits until each accepts connections on one of the TCP ports its
image exposes, or on `HEALTHCHECK_TCP_PORT` from the service's own variables, for up to
`services_timeout` seconds. Then it runs the command anyway. It also waits for services another
command started less than `services_timeout` seconds ago, so parallel commands work on a fresh
environment. Services that expose no port are not waited for.

### Variables

Variables are resolved like in a GitLab job:

- Global `variables:` (limited by the job's `inherit: variables:`) and job variables are merged by
  name. The `.rascal` block and its `jobs:` entries override them, and may extend them by
  referencing their own name.
- Values, image names and service names may reference variables as `$NAME`, `${NAME}` or `%NAME%`.
  `$$` stands for a literal `$`. A variable defined as `{ value: ..., expand: false }` is used as is.
- References only see variables from the CI config and the ones rascal predefines, not variables the
  image sets.
- rascal predefines `CI=true`, `GITLAB_CI=true`, `CI_JOB_NAME`, `CI_BUILDS_DIR` (`/builds`),
  `CI_PROJECT_DIR` (`/repo`, or your `repo_dir`) and `CI_PROJECT_NAME` (the name of your project
  directory). Tools may behave differently when `CI` is set. For example, `pnpm install` refuses to
  change the lockfile. Override them in the `.rascal` block if needed, or remove them with
  `CI: null`, since some tools only check whether `CI` is set.
- An undefined `$NAME` in a variable's value becomes an empty string, like in GitLab, and rascal
  warns about it. An undefined `%NAME%` stays as it is. An undefined variable in an image name keeps
  rascal from starting the job.


## Troubleshooting

rascal explains most problems itself. These are the messages you may see, and what to do.

Run `rascal status <job>` to see what rascal made of the job's config, and what of it runs (see
[Look at the environment](#2-look-at-the-environment)).

#### `Could not find a .gitlab-ci.yml in ...`

Run rascal in the project's root directory, or pass `--config-file`.

#### `Unknown job ... Jobs: ...`

Use one of the listed job names. Jobs starting with a dot are templates, which have no environment.

#### `has no image`

The job gets its image from somewhere rascal cannot see, often an include from another project.
Set it in the `.rascal` block: `jobs: <job>: image: ...`.

#### `uses the undefined variable`

The image of the job or of a service references a variable rascal does not know, often one GitLab
sets, like `CI_REGISTRY_IMAGE`. Define it under `variables:` in the `.rascal` block, or set the image
there.

#### ``unknown keys in `extends` `` or `could not be found`

A template or `!reference` comes from a file rascal cannot read. Set the config the job needs in the
`.rascal` block, or hide the job with `jobs: <job>: hide: true` if you do not need it.

#### `rascal cannot read these includes`

The job may lack services or variables from includes of other projects, URLs or templates. If it
does, set them in the `.rascal` block. Otherwise, ignore the warning.

#### ``uses `spec: inputs:` ``

rascal does not interpolate `$[[ inputs.name ]]`. Set the value in the `.rascal` block.

#### `which is undefined and expanded to an empty string`

Harmless if the command does not need the variable. Otherwise define it in the `.rascal` block.

#### `Docker may need credentials for ...`

Run the `docker login` command from the message.

#### `Docker found no image ... in its registry`

The image named in the CI config is gone from its registry, often because an old tag was deleted,
so the project's CI pipeline is probably broken too. Find an existing tag in the registry, like on
the Container Registry page of the GitLab project, preferably one with the Ruby and Node versions
the project uses (`.ruby-version`, `.tool-versions`). Set it in the `.rascal` block, like
`jobs: <job>: image: ...`, or override the job's `services:` there. If the project builds its CI
image itself, like from a `Dockerfile`, you can also build it under the name from the message.
`rascal update` cannot update such an image.

#### `rascal is not provided by the active ruby` or `rascal: command not found` inside a project

A Ruby version manager switched to the project's Ruby, which does not have rascal. Run rascal with
the Ruby you installed it for, which mise's message names. See [Installation](#installation).

#### `Cannot connect to the Docker daemon` or `failed to connect to the docker API`

Start Docker.

#### Gems or packages are missing after they were installed

They were installed outside the project directory, in a container that is gone now. See
[Settings that need to persist](#settings-that-need-to-persist).

#### `does not accept connections ... continuing anyway`

The service needs longer to start, or listens on a port its image does not declare. Set
`services_timeout` in the `.rascal` block, or `HEALTHCHECK_TCP_PORT` in the service's variables.

#### `Service ... is not running anymore`

The service stopped, usually because of missing settings, like a database password. Its logs say
why: `rascal status <job>` shows the command, like `docker logs rascal-myapp-rspec_db`. Fix its variables in the `.rascal` block, then run `rascal clean <job>`.

#### `not a git repository` from Git in the container

The project is a Git worktree, whose `.git` points to the main repository outside the project
directory, which the container cannot see. Run Git on your machine instead, or use a clone. (In a
clone, Git works in the container: rascal tells it to trust the project, which belongs to you and
not to the container's user.)

#### `Host key verification failed` or `Permission denied (publickey)` when fetching dependencies

Enable `ssh_agent: true` (see [Private dependencies over SSH](#private-dependencies-over-ssh)), and
make sure your agent holds a key for the Git server (`ssh-add -l`) and that `~/.ssh/known_hosts`
knows the server.

#### The image's entrypoint fails or refuses to run before your command

Messages like `Refusing to run as root` come from the image's entrypoint, not from rascal or your
command. See [An image's entrypoint that gets in the way](#an-images-entrypoint-that-gets-in-the-way).

#### Tests pass, but an `after(:suite)` hook of Knapsack fails

Many projects split their tests across CI machines with Knapsack, and turn it on when `CI` is set,
which rascal sets like GitLab. Knapsack then expects files that CI provides, like
`knapsack_rspec_report.json`, and fails the run after all tests passed. Look at how the project turns
on Knapsack, usually in `spec/spec_helper.rb`. If only `CI` turns it on, run the tests with
`--unset-env CI` (keeping in mind that other code may check `CI` too), or give Knapsack the file the
message names, outside Git.

#### `"bash": executable file not found`

The job's image has no bash, so rascal cannot use it. Use another job, or set another image for the
job in the `.rascal` block.

#### The database or another service is in a bad state

Run `rascal clean <job>` to remove the services and their data. The next command starts them
fresh.

#### Leftovers from a project directory you deleted

Find them with `docker ps --all --filter name=rascal-`, `docker network ls --filter name=rascal-`
and `docker volume ls --filter name=rascal-`. Remove them with `docker rm --force`,
`docker network rm` and `docker volume rm`.


## Working on rascal

See [CONTRIBUTING.md](CONTRIBUTING.md) for how rascal is built, how to run its tests and where
changes go.


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
