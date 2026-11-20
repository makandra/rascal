# Working on rascal

This guide is for people and AI agents who change rascal. For using rascal, see the
[README](README.md).


## Setup

You need Ruby 3.3 or newer and a running Docker daemon. Install the dependencies with
`bundle install`.

To try your working copy on a project, run its executable from the project directory, with the Ruby
from rascal's `.ruby-version` (it needs the gems from `bundle install`, not the project's):

```sh
cd ~/projects/myapp
mise exec ruby@4.0.9 -- ruby ~/projects/rascal/exe/rascal run rspec -- bundle exec rspec
```


## How rascal is built

A command like `rascal run rspec -- rake` flows through four layers. Each change usually belongs in
one of them.

| Layer | Code | Responsibility |
|---|---|---|
| Command line | `lib/rascal/cli/` | `Main` defines the commands and options with Thor. Each command has a small class that finds the job and calls the environment. |
| CI config | `lib/rascal/gitlab/` | Turns `.gitlab-ci.yml` into an `Environment` for a job, like GitLab would read it. |
| Environment | `lib/rascal/environment.rb`, `service.rb`, `command_script.rb` | Starts a job's services, runs commands, cleans up, reports status. |
| Docker | `lib/rascal/docker/` | Everything that calls `docker`. |

`IOHelper` decides where output goes: `say` writes to stdout, which belongs to the command's output,
`info` and `warning` write rascal's own messages to stderr.

### CI config: `Rascal::Gitlab`

- `ConfigFile` reads the YAML with its local `include:` files, and marks `!reference` tags.
- `Jobs` resolves each job like GitLab does (`extends:`, `default:`, `inherit:`, `!reference`), and
  applies rascal's settings from the `.rascal` block and `.rascal.yml` on top. The result is a
  `Job`: the job's config, its variables in layers, and its problems and warnings.
- `EnvironmentBuilder` turns a `Job` into an `Environment`: Docker names, volumes, the image, the
  services and their aliases, and the expanded variables.
- `Variables` expands variable references like GitLab does.

Where a change goes:

- **A GitLab keyword that changes how jobs combine,** like `extends:`, goes into `Jobs`. A new global
  keyword must be added to `Jobs::GLOBAL_KEYS`, or rascal takes it for a job.
- **A keyword rascal should use,** like a service's `entrypoint`, is read in `EnvironmentBuilder` and
  passed on to `Environment` or `Service`, and from there to `Docker::*`.
- **A rascal setting** is read like a keyword. Also validate it as a problem (see
  `EnvironmentBuilder#services_timeout`), show it in `Environment#status` and `CLI::Status`, and
  document it in the README's Configuration section. If it may hold a `!reference`, add it to
  `Jobs::KEYS_WITH_REFERENCES`.
- **An option for a single command** goes into `Main.command_environment_options` and
  `Base#command_overrides`.

When unsure how GitLab treats something, look at GitLab's source (`lib/gitlab/ci/`), which the code
comments point to.

Problems and warnings are a core idea. A **problem** keeps a job's environment from starting, like a
missing image, but `rascal clean`, `environments` and `status` still work for it. A **warning** is
printed before each command, since it may make commands fail. Both are collected per job while
building the environment. Only a file rascal cannot read at all, like broken YAML, raises an error.

### Environment and Docker

- `Environment` starts the network and services under a lock (so parallel commands do not start them
  twice), waits for services that are still starting, and runs each command in a new container.
- `CommandScript` writes the bash script around a command: waiting for services, `before_shell`, the
  command, `after_shell`, and giving files back to the host user.
- `Service` is one service of a job, in a long-lived `Docker::Container`.
- `Docker::Image` downloads images and reads their exposed ports and entrypoint.
  `Docker::CommandContainers` runs the one-off containers of commands, and removes them when rascal
  gets a signal. `Docker::Network` and `Docker::Volume` are what their names say.
- `Docker::Interface` is the only place that runs `docker` (except a signal handler, which must not).
  Specs replace it with a mock.


## Tests

All tests are RSpec specs, of three kinds:

| Tests | Location | What they cover | Speed |
|---|---|---|---|
| Unit specs | `spec/rascal/`, named like the class | Reading CI configs, variables, the command script, and other logic. Most tests belong here. How jobs combine goes into `gitlab/jobs_spec.rb`, how rascal uses a job into `gitlab/environment_builder_spec.rb`. Both write a `.gitlab-ci.yml` with the helpers in `spec/support/gitlab.rb`. | Fast |
| CLI specs | `spec/cli/`, one file per command, plus `starting_an_environment_spec.rb` | The command line, with a mocked Docker (`spec/support/docker_mock.rb`) that records which `docker` commands rascal would call. Also what real Docker cannot show easily, like `rascal shell` with a TTY or broken networks. | Fast |
| Integration specs | `spec/integration/` | The real `rascal` executable against a real Docker daemon. | About 30 seconds, plus pulling small images on the first run |

```sh
bundle exec rake                        # everything, like CI does
bundle exec rspec --tag ~integration    # only the fast specs
bundle exec rspec --tag integration     # only the integration specs
```

The integration specs fail with an explanation when Docker is not running. They do not skip, so a
green run always means everything was tested. Every spec in `spec/integration/` is tagged with
`integration: true` automatically.

Test each behavior once, at the cheapest level that can show it works:

- Reading and resolving CI configs belongs in unit specs, with one example per variation.
- What rascal does with Docker belongs in integration specs, for key paths and for behavior only
  real Docker can show, like a job reaching its services by their alias, or exit statuses passing
  through. Do not add one for every variation of a CI config.
- CLI specs cover the rest: command line errors and output, and situations that are hard to create
  with real Docker.

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


## Conventions

- **Read CI configs like GitLab.** Where rascal reads `.gitlab-ci.yml`, it should behave like GitLab,
  so a project needs no changes to its CI config for rascal. Settings for rascal go into the
  `.rascal` block or `.rascal.yml`.
- **Help people out of trouble.** When something is likely to go wrong, prefer, in this order: a
  message that explains the cause and the remedy; a troubleshooting entry in the README; a command
  that fixes it. Fix things automatically only when there is no doubt that they are wrong, like files
  owned by root in the project, since surprising changes confuse people and agents.
- **Keep messages and the README in sync.** Troubleshooting entries in the README are headed by the
  text of the message they explain, so people find them by searching for the message.
- **Document what users notice.** Update the README, the command help in `lib/rascal/cli/main.rb`
  where it applies, and add a line to the "Unreleased" section of `CHANGELOG.md` for every change in
  behavior.
- **Do not cache Docker state to save time.** Stale state causes worse problems than a few
  milliseconds per `docker` call.
