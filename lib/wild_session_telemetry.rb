# frozen_string_literal: true

require_relative 'wild_session_telemetry/version'
require_relative 'wild_session_telemetry/errors'
require_relative 'wild_session_telemetry/configuration'

module WildSessionTelemetry
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
