require 'digest/sha1'

# Replaces the Docker CLI for specs that check which docker commands rascal calls,
# without a Docker daemon. It records every command and answers queries from a
# small fake state of images, containers and volumes.
class DockerMockInterface < Rascal::Docker::Interface
  include RSpec::Mocks::ExampleMethods

  # The mock answers every `network ls` with this id, so it is the id of the
  # environment's current network. Any other id belongs to a network that is gone.
  NETWORK_ID = 'deadbeef'

  attr_reader :history, :images, :containers, :volumes
  attr_accessor :attached_exit_code

  def initialize(*)
    @attached_exit_code = 0
    @history = []
    @images = Hash.new { |h, k| h[k] = {} }
    @containers = Hash.new { |h, k| h[k] = {} }
    @volumes = Hash.new { |h, k| h[k] = {} }
    @counter = 0
    super
  end

  # The docker commands called so far, each as a single string like "docker pull image:latest".
  def commands
    @history.map { |command| command.reject { |part| part.is_a?(Hash) }.join(' ') }
  end

  def image_exists(name, exposed_ports: [])
    @images[name] = {
      Id: Digest::SHA1.hexdigest("image-#{name}"),
      Config: { ExposedPorts: exposed_ports.to_h { |port| [port, {}] } },
    }
  end

  def container_exists(name, running: false, network_id: nil)
    @containers[name] = { id: Digest::SHA1.hexdigest("container-#{name}") }
    @containers[name][:State] = { Running: true } if running
    @containers[name][:NetworkSettings] = { Networks: { 'some-network' => { 'NetworkID' => network_id } } } if network_id
  end

  def container_id(name)
    @containers[name][:id]
  end

  def volume_exists(name)
    @volumes[name] = { id: Digest::SHA1.hexdigest("volume-#{name}") }
  end

  private

  def spawn(*command)
    @history << command
    exit_status(@attached_exit_code.zero?, @attached_exit_code)
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
      # Like docker, an array with one entry for an existing image.
      (@images.key?($1) ? [@images[$1]] : []).to_json
    when /pull (\S*)/
      "[Docker mock] Pulling #{$1}"
    when /network ls.*name=\^(.*)\$/
      NETWORK_ID
    when /volume ls.*name=\^(.*)\$/
      @volumes[$1][:id]
    when /container ps.*name=\^\/(.*)\$/
      @containers[$1][:id]
    when /container create --name (\S*)/
      new_id = "%08x" % (@counter += 1)
      @containers[$1] = { id: new_id }
      new_id
    when /container rm (?:--volumes )?(\S*)/
      @containers.delete_if { |_name, container| container[:id] == $1 }
      $1
    when /container inspect (.*)/
      container = @containers.values.detect { |c| c[:id] == $1 }
      if container
        [container].to_json
      else
        :fail
      end
    end
  end

  def exit_status(success = true, code = nil)
    instance_double(Process::Status,
      success?: success,
      exitstatus: code || (success ? 0 : 1),
      termsig: nil,
    )
  end
end
