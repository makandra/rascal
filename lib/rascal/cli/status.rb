require 'json'
require 'rascal'

module Rascal
  module CLI
    # Shows what rascal made of the CI config for an environment, and what of it exists in
    # Docker, so you can see why something does not work without knowing rascal's names.
    class Status < Base
      def initialize(options, environment_name)
        super(options)
        @environment_name = environment_name || :all
      end

      def run
        statuses = each_environment(@environment_name).collect(&:status)
        if @options[:json]
          say JSON.pretty_generate(@environment_name == :all ? statuses : statuses.first)
        else
          say statuses.collect { |status| text(status) }.join("\n")
        end
      end

      private

      def text(status)
        lines = [status['name']]
        hints = status['problems'].empty?
        lines << "  Image:      #{status['image'] || '(none)'}#{image_note(status, hints)}"
        lines << "  Entrypoint: #{status['entrypoint'].inspect}" if status['entrypoint']
        status['problems'].each { |problem| lines << "  Problem:    #{problem}" }
        status['warnings'].each { |warning| lines << "  Warning:    #{warning}" }
        network = status['network']
        lines << "  Network:    #{network['name']}#{' (does not exist)' unless network['exists']}"
        lines << '  Services:' if status['services'].any?
        status['services'].each { |service| lines.concat(service_text(service, hints)) }
        lines << '  Volumes:'
        status['volumes'].each do |volume|
          source = volume['volume'] ? "volume #{volume['volume']}#{' (does not exist)' unless volume['exists']}" : volume['directory']
          lines << "    #{volume['path']}: #{source}"
        end
        lines << "  Command containers: #{status['command_containers'].join(', ')}" if status['command_containers'].any?
        lines << '  Variables:'
        status['variables'].sort.each { |name, value| lines << "    #{name}=#{value}" }
        %w[before_shell after_shell].each do |key|
          next if status[key].empty?

          lines << "  #{key}:"
          status[key].each { |command| lines << "    #{command}" }
        end
        lines << "  ssh_agent: #{status['ssh_agent']}, services_timeout: #{status['services_timeout']}"
        lines.join("\n")
      end

      def service_text(service, hints)
        state = case service['state']
        when 'running' then "running since #{service['started_at']}"
        when 'missing' then hints ? 'not created, the next command starts it' : 'not created'
        when 'created' then 'created, but never started'
        else [service['state'], ("with exit code #{service['exit_code']}" if service['exit_code'])].compact.join(' ')
        end
        image = service['image'].to_s.empty? ? '(none)' : service['image']
        lines = ["    #{service['aliases'].join(', ')}: #{image}#{' (not downloaded)' unless service['image_present']}, #{state}"]
        lines << "      Error: #{service['error']}" if service['error']
        lines << "      Waits for port #{service['wait_ports'].join(' or ')}" if service['wait_ports']&.any?
        lines << "      Logs: #{service['logs']}" unless %w[missing created].include?(service['state'])
        lines
      end

      def image_note(status, hints)
        return unless status['image'] && !status['image_present']

        hints ? ' (not downloaded, the next command downloads it)' : ' (not downloaded)'
      end
    end
  end
end
