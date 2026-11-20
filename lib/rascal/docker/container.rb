require 'time'

module Rascal
  module Docker
    # A long-lived container that runs a service, like a database, under a fixed name.
    class Container
      include IOHelper

      attr_reader :prefixed_name

      # `image` is a Docker::Image.
      def initialize(name, image)
        @name = name
        @prefixed_name = "#{NAME_PREFIX}#{name}"
        @image = image
      end

      # When the container was last started, or nil.
      def started_at
        started_at = inspection&.dig('State', 'StartedAt')
        Time.parse(started_at) if started_at && !started_at.start_with?('0001-')
      end

      def running?
        !!inspection&.dig('State', 'Running')
      end

      # For `rascal status`: the container's name, and its state like "running", "exited"
      # or "missing", with when it started and how it exited.
      def status
        state = inspection&.dig('State')
        return { 'container' => @prefixed_name, 'state' => 'missing' } unless state

        status = state['Status'] || (state['Running'] ? 'running' : 'exited')
        {
          'container' => @prefixed_name,
          'state' => status,
          'started_at' => started_at&.iso8601,
          'exit_code' => (state['ExitCode'] if %w[exited dead].include?(status)),
          # Why Docker could not start it, like a missing command.
          'error' => (state['Error'] unless state['Error'].to_s.empty?),
        }.compact
      end

      def exists?
        !!id
      end

      def attached_to?(network)
        attached_network_ids.include?(network.id)
      end

      # Docker resolves a container's network by the id it recorded when the
      # container was created, and refuses to start it once that network is
      # gone:
      #
      #   failed to set up container networking: network 36243f82141a... not found
      #
      # `docker network prune` (and `docker system prune`) leaves exactly that
      # behind, because it removes networks whose containers are all stopped —
      # the normal state of an environment between runs. Reconnecting does not
      # help, since docker resolves the recorded id before it looks at the
      # container's current endpoints, so the container has to go. Nothing in a
      # service container is worth preserving; #start creates a new one.
      def remove_if_network_missing(network)
        return unless exists?
        attached = attached_network_ids
        return if attached.empty? || attached.include?(network.id)

        info "Removing container for #{@name}, its network no longer exists"
        remove_container
        @id = nil
      end

      # Creates the container if it does not exist, and starts it.
      def start(network:, network_aliases: [], volumes: [], env: {}, command: [])
        info "Starting container for #{@name}"
        create(network: network, network_aliases: network_aliases, volumes: volumes, env: env, command: command) unless exists?
        Docker.interface.run('container', 'start', id)
      end

      def clean
        if running?
          info "Stopping container for #{@name}"
          Docker.interface.run('container', 'stop', id)
        end
        if exists?
          info "Removing container for #{@name}"
          remove_container
        end
      end

      def id
        @id ||= Docker.interface.run(
          'container',
          'ps',
          '--all',
          '--quiet',
          '--filter', "name=^/#{@prefixed_name}$",
          output: :id,
        )
      end

      private

      def create(network:, network_aliases:, volumes:, env:, command:)
        @id = Docker.interface.run(
          'container',
          'create',
          '--name', @prefixed_name,
          *volumes.flat_map { |volume| ['-v', volume.to_param] },
          *Docker.env_args(env),
          '--network', network.id,
          *network_aliases.flat_map { |network_alias| ['--network-alias', network_alias] },
          @image.name,
          *command,
          output: :id,
        )
      end

      # A fresh `docker container inspect`, or nil if there is no container.
      def inspection
        return unless id

        Docker.interface.run('container', 'inspect', id, output: :json).first
      end

      # Ids of the networks the container is attached to. Empty for a container
      # that was created but never started.
      def attached_network_ids
        networks = inspection&.dig('NetworkSettings', 'Networks') || {}
        networks.each_value.filter_map { |n| n['NetworkID'] }.reject(&:empty?).uniq
      end

      # Also removes the container's anonymous volumes, like the data volume that
      # the postgres and redis images declare. Named volumes are kept.
      def remove_container
        Docker.interface.run('container', 'rm', '--volumes', id)
      end
    end
  end
end
