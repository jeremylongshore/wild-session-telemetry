# frozen_string_literal: true

require_relative 'wild_session_telemetry/version'
require_relative 'wild_session_telemetry/errors'
require_relative 'wild_session_telemetry/configuration'
require_relative 'wild_session_telemetry/schema/event_envelope'
require_relative 'wild_session_telemetry/schema/validator'
require_relative 'wild_session_telemetry/store/base'
require_relative 'wild_session_telemetry/store/memory_store'
require_relative 'wild_session_telemetry/store/json_lines_store'
require_relative 'wild_session_telemetry/store/retention_manager'
require_relative 'wild_session_telemetry/store/storage_monitor'
require_relative 'wild_session_telemetry/privacy/filter'
require_relative 'wild_session_telemetry/collector/event_receiver'

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
