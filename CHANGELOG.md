# Rascal Changelog

All notable changes to this project will be documented here.

Rascal follows semantic versioning. This has little consequence pre 1.0, so expect breaking changes.

## 0.5.2 (2026-11-20)

- Run on Ruby 3.0 or newer again. 0.5.0 and 0.5.1 required Ruby 3.3, which locked out projects that
  pin an older Ruby, like Rails LTS checkouts with Ruby 3.1.


## 0.5.1 (2026-11-20)

- Fix services that were unreachable by their alias after rascal restarted their stopped container
  (with current Docker versions). rascal now connects such containers to the network again, also
  ones that an earlier version left running without a network. It recreates service containers
  whose network was removed, like by `docker network prune`, also when they have no network
  endpoints or still run.


## 0.5.0 (2026-11-20)

### Breaking changes

- Require Ruby 3.3 or newer for rascal itself. Projects can still use any Ruby in their images.
- Predefine the variables `CI`, `GITLAB_CI`, `CI_JOB_NAME`, `CI_PROJECT_NAME`, `CI_PROJECT_DIR` and
  `CI_BUILDS_DIR`, like GitLab does. **This may change how your app and tools behave in a rascal
  environment**, if they check for `CI` or `GITLAB_CI`. Override or remove them in the `.rascal` block if needed.
- Let a job override `default:`, like GitLab does. Rascal used to do it the other way around.
- rascal's own messages, like `Starting container for ...` and image downloads, go to stderr, so a
  command's stdout only has the command's output.
- After starting services, wait until each accepts connections on one of its exposed ports, or
  on `HEALTHCHECK_TCP_PORT` from its variables, before running the command. Set the timeout
  (30 seconds by default) with `services_timeout` in the `.rascal` block.
- `rascal clean` also removes the anonymous volumes of service containers, like the data volumes of
  postgres and redis, which used to pile up.
- `before_shell`, the command and `after_shell` run on separate lines of a script instead of being
  joined with `;`, so entries may end in `&` or a comment.

### GitLab compatibility

- Read `.gitlab-ci.yml` files with global `variables:` or `workflow:`, which rascal used to mistake
  for jobs, like `include:` and `stages:`. The deprecated top-level `image`,
  `services`, `cache`, `before_script` and `after_script` now act like the same keys in `default:`.
- Support `extends:`, `inherit:`, `!reference`, local files from `include:`, and files with a `spec:` header.
- Support services given as a plain image name, services with several aliases (`alias: db,postgres`),
  and services without an alias, which get the host names GitLab derives from their image.
- Expand variables in variables, image names and service names, like GitLab does
  (`$NAME`, `${NAME}`, `%NAME%`, `$$`). Global `variables:` apply to every job.
- Support `entrypoint` for a job's image. rascal's settings can override only the entrypoint, like
  `jobs: rspec: image: { entrypoint: [''] }`, keeping the job's image.
- Job names like `2.6`, which YAML reads as numbers, work in `.rascal: jobs:`.

### Working with environments

- Add `rascal status`, which shows what rascal made of a job's config, and what of the environment
  exists in Docker, like whether a service runs or how it exited, or what the image's entrypoint is.
  `--json` prints it for scripts.
- Add the options `--env NAME=VALUE`, `--unset-env NAME` and `--ssh-agent` to `rascal run` and
  `rascal shell`, which change the container for a single command, like for updating dependencies.
  Options may also come after the environment's name.
- In the `.rascal` block, a variable can extend the job's value, like `RUBYOPT: $RUBYOPT -W:deprecated`,
  or remove a variable, like `CI: null`.
- Read settings for rascal from a `.rascal.yml` next to `.gitlab-ci.yml`, which extends the `.rascal`
  block. Use it for settings that should not be part of the project's CI config.
- With `ssh_agent: true` in the `.rascal` block, make the host's SSH agent and known hosts available
  in the container, so it can fetch private dependencies over SSH. It is off by default, since any
  code in the container can use the agent's keys while a command runs.
- Give files that commands create in the project back to the host user. They used to belong to root.
- Let Git in the container work with the project, which it used to refuse as belonging to another user.
- `rascal run` passes stdin to the command when it comes from a file or a pipe.
- When rascal gets a signal while running a command, it removes the command's container, which kept
  running before. `rascal clean` removes such containers left over from earlier versions or `kill -9`.
- Several commands can start the same environment at once.

### Messages

- Explain what is wrong when a job has no image, its image uses an undefined variable, its
  `extends:` templates cannot be resolved, or its `services_timeout` is not a number.
  `rascal clean` and `rascal environments` still work for such jobs, and `rascal update --all` skips them.
- Warn about variables that reference undefined variables, like ones set in the project's CI/CD
  settings, and about includes rascal cannot read.
- Suggest `docker login` when an image cannot be pulled for lack of credentials, explain what to do
  when an image does not exist in its registry, and explain where rascal looked for `.gitlab-ci.yml`.
- Point to the logs of services that stopped, like when their settings are wrong.
- Explain each command in `rascal help <command>`, which calls the argument a job, like the README.


## 0.4.1 (2026-07-30)

- Recreate a service container whose network no longer exists, instead of failing
  to start it.


## 0.4.0 (2026-07-30)

- Add `rascal run ENVIRONMENT -- COMMAND`, which runs a single command in an
  environment without a TTY and exits with the command's status. Useful for
  scripts, git hooks and AI agents, which cannot drive `rascal shell`.
- Add `rascal environments`, which lists available environment names on stdout.


## 0.3.9 (2026-06-19)

- Support variables within service definitions.
- Drop support for Ruby < 3.


## 0.3.8 (2025-02-10)

- Ruby 3.4 support.


## 0.3.7 (2024-03-22)

- Ignore `stage:` blocks in .gitlab-ci.yml.


## 0.3.6 (2023-01-27)

- Handle `default:` blocks in .gitlab-ci.yml.


## 0.3.5 (2022-12-21)

- Fix the "endpoint ... already exists in network" error.


## 0.3.4 (2022-03-16)

- Activate Rubygems MFA


## 0.3.3 (2021-12-08)

- Support `command` key in services.


## 0.3.2 (2020-10-23)

- Fix broken `rascal shell` command.


## 0.3.1 (2020-10-01)

- Pass env variables to service containers.


## 0.3.0 (2020-09-23)

- Mount /repo into all service volumes


## 0.2.1 (2019-04-10)

- Prefix names with directory name, to avoid conflicts between projects.


## 0.2.0 (2019-04-10)

- Add `--all` flag for `rascal clean`.
- Add `rascal update` command.
- Allow rascal specific per job config.


## 0.1.0 (2019-03-21)

initial release
