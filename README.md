# Rascal
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

This is an early alpha version. Use at your own risk.

Only the parsing of `.gitlab-ci.yml` is currently supported, and only a subset of the possible syntax
will be properly interpreted.


## Usage

You need to add some extra information to your `.gitlab-ci.yml`. A working version might look like this:

```
# settings here override job settings
.rascal:
  repo_dir: /repo
  variables:
    BUNDLE_PATH: /cache/bundle
  volumes:
    cache: /cache
  before_shell:
    - bundle check

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
    DATABASE_CLEANER_ALLOW_REMOTE_DATABASE_URL: "true"
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


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
