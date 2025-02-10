# Rascal Changelog

All notable changes to this project will be documented here.

Rascal follows semantic versioning. This has little consequence pre 1.0, so expect breaking changes.

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
