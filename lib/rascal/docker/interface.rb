require 'json'
require 'open3'

module Rascal
  module Docker
    class Interface
      class Error < Rascal::Error; end

      def run(*command, output: :ignore, stdout: nil, allow_failure: false)
        save_stdout = ''
        save_stderr = ''
        exit_status = nil
        popen3('docker', *stringify_command(command)) do |docker_stdin, docker_stdout, docker_stderr, wait_thr|
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
        parse_output(output, save_stdout, save_stderr)
      end

      def run_and_attach(*command, stdout: nil, stderr: nil, stdin: nil, env: {}, network: nil, volumes: [], working_dir: nil, redirect_io: {}, allow_failure: false)
        exit_status = spawn(env, 'docker', *stringify_command(command), redirect_io)
        unless allow_failure || exit_status.success?
          raise Error, "docker container run failed"
        end
      end

      private

      def stringify_command(command)
        command.collect(&:to_s)
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

      def parse_output(output, stdout, stderr)
        case output
        when :json
          begin
            JSON.parse(stdout)
          rescue JSON::ParserError
            raise Error, "could not parse output of docker command '#{command.join(' ')}':\n#{stdout}"
          end
        when :id
          stdout[/[0-9a-f]+/]
        when :ignore
          nil
        else
          raise ArgumentError, 'unknown option for :output'
        end
      end
    end
  end
end
