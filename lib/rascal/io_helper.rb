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
