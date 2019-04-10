module Rascal
  class Service
    attr_reader :name, :container, :alias

    def initialize(name, image:, alias_name:)
      @name = name
      @container = Docker::Container.new(name, image)
      @alias = alias_name
    end

    def download_missing
      @container.download_missing
    end

    def start_if_stopped(network: nil)
      unless @container.running?
        @container.start(network: network, network_alias: @alias)
      end
    end

    def clean
      @container.clean
    end

    def update(**args)
      @container.update(**args)
    end
  end
end
