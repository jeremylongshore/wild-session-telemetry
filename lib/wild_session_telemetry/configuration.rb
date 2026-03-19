# frozen_string_literal: true

module WildSessionTelemetry
  class Configuration
    attr_reader :store, :retention_days, :privacy_mode, :max_storage_bytes

    def initialize
      @store = nil
      @retention_days = 90
      @privacy_mode = :strict
      @max_storage_bytes = nil
    end

    def store=(value)
      check_frozen!
      @store = value
    end

    def retention_days=(value)
      check_frozen!
      @retention_days = value
    end

    def privacy_mode=(value)
      check_frozen!
      @privacy_mode = value
    end

    def max_storage_bytes=(value)
      check_frozen!
      @max_storage_bytes = value
    end

    def freeze!
      freeze
    end

    private

    def check_frozen!
      raise FrozenError, "can't modify frozen #{self.class}" if frozen?
    end
  end
end
