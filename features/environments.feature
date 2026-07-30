Feature: Run "environments"

  Scenario: List available environments, one per line
    Given the following gitlab-ci config:
      """
      .rascal:
        jobs:
          job-2:
            name: renamed-job
          hidden-job:
            hide: true
      job-1:
        image: job-image:latest
      job-2:
        image: job-image:latest
      hidden-job:
        image: job-image:latest
      """

    When I successfully run `rascal environments`
    Then the output should contain exactly:
      """
      job-1
      renamed-job
      """


  Scenario: Complain when there is no environment definition
    When I run `rascal environments`
    Then the exit status should not be 0
      And stderr should contain "Could not find an environment definition"
