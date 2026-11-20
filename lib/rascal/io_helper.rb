module Rascal
  module IOHelper
    class << self
      attr_accessor :stdout, :stdin, :stderr

      def setup
        @stdout = $stdout
        @stderr = $stderr
        @stdin = $stdin
      end
    end
    setup

    def say(message)
      stdout.puts(message)
    end

    # Reports what rascal does, like starting a service. Goes to stderr, so the
    # output of a command stays clean for whoever reads it.
    def info(message)
      stderr.puts(message)
    end

    # Reports something that may make commands fail, on stderr.
    def warning(message)
      stderr.puts("Warning: #{message}")
    end

    def stdout
      IOHelper.stdout
    end

    def stderr
      IOHelper.stderr
    end

    def stdin
      IOHelper.stdin
    end
  end
end
