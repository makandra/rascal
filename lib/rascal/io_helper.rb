module Rascal
  module IOHelper
    class << self
      attr_accessor :stdout, :stdin, :stderr
    end
    @stdout = $stdout
    @stderr = $stderr
    @stdin = $stdin

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
