# frozen_string_literal: true

module WildSessionTelemetry
  class Configuration
    attr_accessor :store, :retention_days, :privacy_mode

    def initialize
      @store = nil
      @retention_days = 90
      @privacy_mode = :strict
    end
  end
end
