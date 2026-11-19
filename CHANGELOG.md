# Rascal Changelog

All notable changes to this project will be documented here.

Rascal follows semantic versioning. This has little consequence pre 1.0, so expect breaking changes.

## Unreleased

- Read `.gitlab-ci.yml` files with global `variables:` or `workflow:`, which rascal used to mistake
  for jobs. `include:` and `stages:` are ignored as well. The deprecated top-level `image`,
  `services`, `cache`, `before_script` and `after_script` now act like the same keys in `default:`.
- Support `extends:` and `inherit:`.
- Support services given as a plain image name, and services without an alias, which get the host
  names GitLab derives from their image.
- Expand variables in variables, image names and service names, like GitLab does
  (`$NAME`, `${NAME}`, `%NAME%`, `$$`). Global `variables:` apply to every job.
  In the `.rascal` block, a variable can extend the job's value, like `RUBYOPT: $RUBYOPT -W:deprecated`.
- Warn about variables that reference undefined variables, like ones set in the project's CI/CD settings.
- Predefine the variables `CI`, `GITLAB_CI`, `CI_JOB_NAME`, `CI_PROJECT_NAME`, `CI_PROJECT_DIR` and
  `CI_BUILDS_DIR`. **This may change how your app and tools behave in a rascal environment**, if they
  check for `CI` or `GITLAB_CI`. Override them in the `.rascal` block if needed.
- Let a job override `default:`, like GitLab does. Rascal used to do it the other way around.
- Explain what is wrong when a job has no image, or its image uses an undefined variable.
  `rascal clean` and `rascal environments` still work for such jobs, and `rascal update --all` skips them.
- `rascal clean` also removes the anonymous volumes of service containers, like the data volumes of
  postgres and redis, which used to pile up.
- Job names like `2.6`, which YAML reads as numbers, work in `.rascal: jobs:`.


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
