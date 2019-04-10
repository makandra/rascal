Feature: Update

  Scenario: Update docker images
    Given the following gitlab-ci config:
      """
      job:
        image: job-image:latest
        services:
          - name: service-1-image:latest
            alias: service-1
          - name: service-2-image:stable
            alias: service-2
      """

    When I successfully run `rascal update job`
    Then stdout should contain "Updating image service-1-image:latest"
      And stdout should contain "Updating image service-2-image:stable"
      And docker `pull service-1-image:latest` should have been called
      And docker `pull service-2-image:stable` should have been called
