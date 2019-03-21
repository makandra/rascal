require 'json'
require 'open3'

module Rascal
  module Docker
    class Interface
      class Error < Rascal::Error; end

      def pull(image, stdout: nil)
        run_cli(
          'pull',
          image.to_s,
          stdout: stdout,
        )
      end

      def inspect_image(image, allow_failure: false)
        run_cli(
          'image',
          'inspect',
          image.to_s,
          output: :json,
          allow_failure: allow_failure,
        ).first
      end

      def create_container(image, name, network: nil, network_alias: nil)
        run_cli(
          'container',
          'create',
          '--name', name.to_s,
          *(['--network', network.to_s] if network),
          *(['--network-alias', network_alias.to_s] if network_alias),
          image.to_s,
          output: :id
        )
      end

      def id_for_container_name(name)
        run_cli(
          'container',
          'ps',
          '--all',
          '--quiet',
          '--filter', "name=^/#{name}$",
          output: :id
        )
      end

      def container_info(id)
        run_cli(
          'container',
          'inspect',
          id.to_s,
          output: :json
        ).first
      end

      def start_container(id)
        run_cli(
          'container',
          'start',
          id.to_s,
        )
      end

      def stop_container(id)
        run_cli(
          'container',
          'stop',
          id.to_s,
        )
      end

      def remove_container(id)
        run_cli(
          'container',
          'rm',
          id.to_s,
        )
      end

      def create_network(name)
        run_cli(
          'network',
          'create',
          name.to_s
        )
      end

      def remove_network(id)
        run_cli(
          'network',
          'rm',
          id.to_s
        )
      end

      def id_for_network_name(name)
        run_cli(
          'network',
          'ls',
          '--quiet',
          '--filter', "name=^#{name}$",
          output: :id,
        )
      end

      def remove_volume(name)
        run_cli(
          'volume',
          'rm',
          name.to_s,
        )
      end

      def run_and_attach(image, *command, stdout: nil, stderr: nil, stdin: nil, env: {}, network: nil, volumes: [], working_dir: nil, allow_failure: false)
        process_redirections = {}
        args = []
        if stdout
          process_redirections[:out] = stdout
          args += ['-a', 'STDOUT']
        end
        if stderr
          process_redirections[:err] = stderr
          args += ['-a', 'STDERR']
        end
        if stdin
          process_redirections[:in] = stdin
          args += ['-a', 'STDIN', '--interactive', '--tty']
        end
        if working_dir
          args += ['-w', working_dir.to_s]
        end
        volumes.each do |volume|
          args += ['-v', volume.to_param]
        end
        env.each do |key, value|
          args += ['-e', "#{key}=#{value}"]
        end
        if network
          args += ['--network', network.to_s]
        end
        exit_status = spawn(
          env,
          'docker',
          'container',
          'run',
          '--rm',
          *args,
          image.to_s,
          *command,
          process_redirections,
        )
        unless allow_failure || exit_status.success?
          raise Error, "docker container run failed"
        end
      end

      private

      def run_cli(*command, output: :ignore, stdout: nil, redirect_io: {}, allow_failure: false)
        save_stdout = ''
        save_stderr = ''
        exit_status = nil
        popen3('docker', *command) do |docker_stdin, docker_stdout, docker_stderr, wait_thr|
          docker_stdin.close
          output_threads = [
            read_lines(docker_stdout, save_stdout, stdout),
            read_lines(docker_stderr, save_stderr),
          ]
          exit_status = wait_thr.value
          output_threads.each(&:join)
        end
        unless allow_failure || exit_status.success?
          raise Error, "docker command '#{command.join(' ')}' failed with error:\n#{save_stderr}"
        end
        case output
        when :json
          begin
            JSON.parse(save_stdout)
          rescue JSON::ParserError
            raise Error, "could not parse output of docker command '#{command.join(' ')}':\n#{save_stdout}"
          end
        when :id
          save_stdout[/[0-9a-f]+/]
        when :ignore
          nil
        else
          raise ArgumentError, 'unknown option for :output'
        end
      end

      def spawn(*command)
        pid = Process.spawn(*command)
        Process.wait(pid)
        $?
      end

      def popen3(*command, &block)
        Open3.popen3(*command, &block)
      end

      def read_lines(io, save_to, output_to = nil)
        Thread.new do
          io.each_line do |l|
            output_to&.write(l)
            save_to << l
          end
        rescue IOError
        end
      end
    end
  end
end
