# frozen_string_literal: true

module WildSessionTelemetry
  class Error < StandardError; end
  class ValidationError < Error; end
  class SchemaError < Error; end
  class ConfigurationError < Error; end
  class StorageError < Error; end
end
