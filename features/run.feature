Feature: Run "run"

  Scenario: Run a command in the main container, without a TTY
    Given the following gitlab-ci config:
      """
      job:
        variables:
          foo: bar
        image: job-image:latest
      """
      And the docker image "job-image:latest" exists

    When I successfully run `rascal run job -- bundle exec rake`
    Then docker /container run --rm -a STDOUT -a STDERR -w \/repo -v .*:\/repo -v rascal-aruba-job-builds:\/builds -e CI=true -e GITLAB_CI=true -e CI_JOB_NAME=job -e CI_PROJECT_NAME=aruba -e CI_PROJECT_DIR=\/repo -e CI_BUILDS_DIR=\/builds -e foo=bar --network deadbeef job-image:latest bash -c bundle exec rake;/ should have been called
      And docker /--tty/ should not have been called


  Scenario: Start required services
    Given the following gitlab-ci config:
      """
      job:
        image: job-image:latest
        services:
          - name: service-1-image:latest
            alias: service-1
      """
      And the docker image "job-image:latest" exists
      And the docker image "service-1-image:latest" exists

    When I successfully run `rascal run job -- rake`
    Then docker /container create --name rascal-aruba-job_service-1/ should have been called


  Scenario: Wrap the command in before_shell and after_shell
    Given the following gitlab-ci config:
      """
      .rascal:
        before_shell:
          - bundle check
        after_shell:
          - echo bye
      job:
        image: job-image:latest
      """
      And the docker image "job-image:latest" exists

    When I successfully run `rascal run job -- rake`
    Then docker /container run .* bash -c bundle check;rake;__rascal_status=\$\?;echo bye;exit \$__rascal_status/ should have been called


  Scenario: Keep arguments containing spaces and shell metacharacters intact
    Given the following gitlab-ci config:
      """
      job:
        image: job-image:latest
      """
      And the docker image "job-image:latest" exists

    When I successfully run `rascal run job -- bundle exec ruby test/foo_test.rb -n '/a test name/'`
    Then docker /container run .* bash -c bundle exec ruby test\/foo_test.rb -n \/a\\ test\\ name\// should have been called


  Scenario: Exit with the status of the command
    Given the following gitlab-ci config:
      """
      job:
        image: job-image:latest
      """
      And the docker image "job-image:latest" exists
      And the container command will exit with 3

    When I run `rascal run job -- rake`
    Then the exit status should be 3


  Scenario: Exit with zero when the command succeeds
    Given the following gitlab-ci config:
      """
      job:
        image: job-image:latest
      """
      And the docker image "job-image:latest" exists

    When I run `rascal run job -- rake`
    Then the exit status should be 0


  Scenario: Complain about a missing command
    Given the following gitlab-ci config:
      """
      job:
        image: job-image:latest
      """
      And the docker image "job-image:latest" exists

    When I run `rascal run job`
    Then the exit status should not be 0
      And stderr should contain "Missing command"
      And docker /container run/ should not have been called


  Scenario: Complain about an unknown environment
    Given the following gitlab-ci config:
      """
      job:
        image: job-image:latest
      """

    When I run `rascal run nope -- rake`
    Then the exit status should not be 0
      And stderr should contain "Unknown environment nope. Available: job."
      And docker /container run/ should not have been called


  Scenario: Expand variables in the image and in variables
    Given the following gitlab-ci config:
      """
      variables:
        IMAGE_TAG: '1.2.3'
      job:
        image: registry.example.com/app:$IMAGE_TAG
        variables:
          BUNDLE_PATH: $CI_PROJECT_DIR/tmp/cache/bundle
      """
      And the docker image "registry.example.com/app:1.2.3" exists

    When I successfully run `rascal run job -- rake`
    Then docker /container run .* -e BUNDLE_PATH=\/repo\/tmp\/cache\/bundle --network deadbeef registry.example.com\/app:1.2.3 bash/ should have been called


  Scenario: Complain about a job without an image
    Given the following gitlab-ci config:
      """
      job:
        script: rake
      """

    When I run `rascal run job -- rake`
    Then the exit status should not be 0
      And stderr should contain "Job 'job' has no image. Set `image:` in the job, in `default:`, or in the `.rascal` block."
      And docker /container run/ should not have been called


  Scenario: Complain about an undefined variable in the image
    Given the following gitlab-ci config:
      """
      job:
        image: app:$IMAGE_TAG
      """

    When I run `rascal run job -- rake`
    Then the exit status should not be 0
      And stderr should contain "The image of job 'job' (app:$IMAGE_TAG) uses the undefined variable IMAGE_TAG."
      And docker /pull/ should not have been called
