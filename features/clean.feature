Feature: Clean

  Scenario: Clean when nothing needs to be done
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

    When I successfully run `rascal clean job`
    Then stdout should not contain "Stopping"


  Scenario: Clean when containers are stopped
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

    Given the container "rascal-aruba-job_service-1" exists
      And the container "rascal-aruba-job_service-2" exists
    When I successfully run `rascal clean job`
    Then stdout should not contain "Stopping"
      But stdout should contain "Removing container for aruba-job_service-1"
      And stdout should contain "Removing container for aruba-job_service-2"
      And docker /container rm/ should have been called
      And docker /network rm/ should have been called


  Scenario: Clean when containers are running
    Given the following gitlab-ci config:
      """
      job:
        image: job-image:latest
        services:
          - name: service-1-image:latest
            alias: service-1
      """

    Given the container "rascal-aruba-job_service-1" is running
      And the container "rascal-aruba-job_service-2" is running
    When I successfully run `rascal clean job`
    Then stdout should contain "Stopping container for aruba-job_service-1"
      And stdout should contain "Removing container for aruba-job_service-1"
      And docker /container stop/ should have been called


  Scenario: Clean all environments
    Given the following gitlab-ci config:
      """
      job-1:
        image: job-image:latest
        services:
          - name: service-1-image:latest
            alias: service
      job-2:
        image: job-image:latest
        services:
          - name: service-1-image:latest
            alias: service
      """

    Given the container "rascal-aruba-job-1_service" exists
      And the container "rascal-aruba-job-2_service" exists
    When I successfully run `rascal clean --all`
    Then stdout should contain "Removing container for aruba-job-1_service"
      And stdout should contain "Removing container for aruba-job-2_service"


  Scenario: Clean volumes
    Given the following gitlab-ci config:
      """
      .rascal:
        volumes:
          cache: '/cache'
          foo: '/foo'
      job:
        image: job-image:latest
      """

    Given the volume "rascal-aruba-job-cache" exists
      And the volume "rascal-aruba-job-foo" exists
    When I successfully run `rascal clean job --volumes`
    Then stdout should contain "Removing volume rascal-aruba-job-cache"
      And stdout should contain "Removing volume rascal-aruba-job-foo"
      And docker `volume rm rascal-aruba-job-cache` should have been called
