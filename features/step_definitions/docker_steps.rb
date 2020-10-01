require 'digest/sha1'

class DockerMockInterface < Rascal::Docker::Interface
  include RSpec::Mocks::ExampleMethods

  attr_reader :history, :images, :containers, :volumes

  def initialize(*)
    @history = []
    @images = Hash.new { |h, k| h[k] = {} }
    @containers = Hash.new { |h, k| h[k] = {} }
    @volumes = Hash.new { |h, k| h[k] = {} }
    @counter = 0
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
      output = output_for(*command)
      stdout_writer.puts(output)
      stdout_writer.close
      stderr_writer.close
      exit_status(output != :fail)
    end
    block.call(stdin_writer, stdout_reader, stderr_reader, thread)
  end

  def output_for(*command)
    case command.join(' ')
    when /image inspect (\S*)/
      @images[$1].to_json
    when /pull (\S*)/
      "[Docker mock] Pulling #{$1}"
    when /network ls.*name=\^(.*)\$/
      "deadbeef"
    when /volume ls.*name=\^(.*)\$/
      @volumes[$1][:id]
    when /container ps.*name=\^\/(.*)\$/
      @containers[$1][:id]
    when /container create --name (\S*)/
      new_id = "%08x" % (@counter += 1)
      @containers[$1] = { id: new_id }
      new_id
    when /container inspect (.*)/
      container = @containers.values.detect { |c| c[:id] == $1 }
      if container
        [container].to_json
      else
        :fail
      end
    end
  end

  def exit_status(success = true)
    instance_double(Process::Status, success?: success)
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
  Rascal::Docker.interface.images[name] = { id: Digest::SHA1.hexdigest("image-#{name}") }
end

Given("the container {string} exists") do |name|
  Rascal::Docker.interface.containers[name] = { id: Digest::SHA1.hexdigest("container-#{name}") }
end

Given("the container {string} is running") do |name|
  Rascal::Docker.interface.containers[name] = { id: Digest::SHA1.hexdigest("container-#{name}"), State: { Running: true } }
end

Given("the volume {string} exists") do |name|
  Rascal::Docker.interface.volumes[name] = { id: Digest::SHA1.hexdigest("volume-#{name}") }
end
