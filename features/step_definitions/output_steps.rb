Then("stdout should contain the current version") do
  expect(last_command_stopped).to have_output_on_stdout(an_output_string_including(Rascal::VERSION.to_s))
end
