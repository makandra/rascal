Feature: Help

  @separate-process
  Scenario: Show version
    When I run `rascal -v`
    Then stdout should contain "Rascal version"
      And stdout should contain the current version
