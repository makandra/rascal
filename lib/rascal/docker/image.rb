module Rascal
  module Docker
    # An image, as named in the CI config. Downloads it, and reads what rascal needs from it.
    class Image
      include IOHelper

      attr_reader :name

      def initialize(name)
        @name = name
      end

      def present?
        !@name.to_s.empty? && !inspection.nil?
      end

      # `user` names what needs the image in the message, like `myapp-rspec_db`.
      def download_missing(user:)
        return if present?

        info "Downloading image for #{user}"
        pull
      end

      # Pulls the latest version, unless `skip` has it already. Returns the name of the image.
      def update(skip: [])
        return if skip.include?(@name)

        info "Updating image #{@name}"
        pull
        @name
      end

      # The TCP ports the image declares with EXPOSE, like [5432] for postgres.
      def exposed_tcp_ports
        ports = inspection&.dig('Config', 'ExposedPorts') || {}
        ports.keys.filter_map { |port| port[%r{\A(\d+)/tcp\z}, 1]&.to_i }
      end

      # The image's own entrypoint, like ["sh", "-c"], or nil.
      def entrypoint
        inspection&.dig('Config', 'Entrypoint')
      end

      private

      # A fresh `docker image inspect`, or nil if the image is not there.
      def inspection
        Docker.interface.run('image', 'inspect', @name, output: :json, allow_failure: true).first
      end

      def pull
        Docker.interface.run('pull', @name, stdout: stderr)
      rescue Interface::Error => e
        case e.message
        when /docker daemon|docker\.sock/i
          # Like no permission to use Docker. Docker's message says enough.
          raise
        when /unauthorized|authentication required|denied|no basic auth credentials/i
          registry = @name.include?('/') && @name.split('/').first.match?(/[.:]|\Alocalhost\z/) ? @name.split('/').first : 'docker.io'
          raise Error, "#{e.message.strip}\nDocker may need credentials for #{registry}. Log in with `docker login #{registry}`, then try again."
        when /manifest unknown|name unknown|failed to resolve reference.*: not found/i
          raise Error, "#{e.message.strip}\nDocker found no image #{@name} in its registry. Its tag may have been deleted, or the name is wrong. " \
                       'Set another image in the .rascal block (`jobs: <job>: image:` or `services:`), or build the image yourself under this name.'
        else
          raise
        end
      end
    end
  end
end
