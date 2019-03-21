class DockerMockInterface < Rascal::Docker::Interface
  include RSpec::Mocks::ExampleMethods

  attr_reader :history, :images

  def initialize(*)
    @history = []
    @images = Hash.new { |h, k| h[k] = [] }
    super
  end

  def flat_history
    @history.map { |e| e.join(' ') }
  end

  private

  def spawn(*command)
    @history << command
    exit_status
  end

  def popen3(*command, &block)
    @history << command
    stdin_reader, stdin_writer = IO.pipe
    stdout_reader, stdout_writer = IO.pipe
    stderr_reader, stderr_writer = IO.pipe
    thread = Thread.new do
      sleep 0.01
      stdin_reader.close
      stdout_writer.puts(output_for(*command))
      stdout_writer.close
      stderr_writer.close
      exit_status
    end
    block.call(stdin_writer, stdout_reader, stderr_reader, thread)
  end

  def output_for(*command)
    case command.join(' ')
    when /image inspect (\S*)/
      @images[$1].to_json
    when /pull (\S*)/
      "[Docker mock] Pulling #{$1}"
    end
  end

  def exit_status
    instance_double(Process::Status, success?: true)
  end
end


Before do
  Rascal::Docker.interface = DockerMockInterface.new
end


Then("docker {command} should have been called") do |command|
  history = Rascal::Docker.interface.flat_history
  expect(history).to include("docker #{command}"), "expected to find #{command} in:\n#{history.join("\n")}"
end

Then("docker {regexp} should have been called") do |regexp|
  history = Rascal::Docker.interface.flat_history.join("\n")
  expect(history).to match(/docker #{regexp}/), "expected to find #{regexp} in:\n#{history}"
end

Then("docker {command} should not have been called") do |command|
  expect(Rascal::Docker.interface.flat_history).not_to include("docker #{command}")
end


Given("the docker image {string} exists") do |name|
  Rascal::Docker.interface.images[name] = { id: "id-#{name}" }
end
