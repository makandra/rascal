ParameterType(
  name: 'command',
  regexp: /`([^`]+)`/,
  type: String,
  transformer: ->(string) { string },
)

ParameterType(
  name: 'regexp',
  regexp: %r{/(.*)/},
  type: Regexp,
  transformer: ->(string) { Regexp.new(string) },
)
