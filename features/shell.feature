Feature: Run "shell"

  Scenario: Download main and service images
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

    When I successfully run `rascal shell job`
    Then stdout should contain:
      """
      Downloading image for aruba-job
      [Docker mock] Pulling job-image:latest
      Downloading image for aruba-job_service-1
      [Docker mock] Pulling service-1-image:latest
      Downloading image for aruba-job_service-2
      [Docker mock] Pulling service-2-image:stable
      """
    Then docker `pull job-image:latest` should have been called
      And docker `pull service-1-image:latest` should have been called
      And docker `pull service-2-image:stable` should have been called


  Scenario: Do not download existing images
    Given the following gitlab-ci config:
      """
      job:
        image: job-image:latest
      """
      And the docker image "job-image:latest" exists

    When I successfully run `rascal shell job`
    Then docker `pull job-image:latest` should not have been called


  Scenario: Start services if not running
    Given the following gitlab-ci config:
      """
      job:
        variables:
          foo: bar
        image: job-image:latest
        services:
          - name: service-1-image:latest
            alias: service-1
          - name: service-2-image:stable
            alias: service-2
            command: bin/start
      """

    When I successfully run `rascal shell job`
    Then docker /container create --name rascal-aruba-job_service-1 -v .*:/repo -v rascal-aruba-job-builds:/builds -e foo=bar --network deadbeef --network-alias service-1 service-1-image:latest/ should have been called
      And docker /container create --name rascal-aruba-job_service-2 -v .*:/repo -v rascal-aruba-job-builds:/builds -e foo=bar --network deadbeef --network-alias service-2 service-2-image:stable bin\/start/ should have been called
      And docker /container start 00000001/ should have been called
      And docker /container start 00000002/ should have been called
      And stdout should contain:
        """
        Starting container for aruba-job_service-1
        Starting container for aruba-job_service-2
        """


  Scenario: Run main container
    Given the following gitlab-ci config:
      """
      job:
        variables:
          foo: bar
        image: job-image:latest
      """

    When I successfully run `rascal shell job`
    Then docker /container run --rm -a STDOUT -a STDERR -a STDIN --interactive --tty -w /repo -v .*:/repo -v rascal-aruba-job-builds:/builds -e foo=bar --network deadbeef job-image:latest bash/ should have been called
