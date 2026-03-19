# frozen_string_literal: true

require_relative 'lib/wild_session_telemetry/version'

Gem::Specification.new do |spec|
  spec.name = 'wild-session-telemetry'
  spec.version = WildSessionTelemetry::VERSION
  spec.authors = ['Intent Solutions']
  spec.summary = 'Privacy-aware telemetry collection from agent sessions'
  spec.description = 'Library for collecting, validating, storing, and exporting ' \
                     'privacy-aware telemetry events from admin-tools-mcp pipeline ' \
                     'operations. Schema validation, metadata allowlisting, and ' \
                     'fire-and-forget ingestion semantics.'
  spec.homepage = 'https://github.com/jeremylongshore/wild-session-telemetry'
  spec.license = 'Nonstandard'
  spec.required_ruby_version = '>= 3.2.0'

  spec.files = Dir['lib/**/*.rb', 'LICENSE', 'README.md']
  spec.require_paths = ['lib']

  spec.metadata['rubygems_mfa_required'] = 'true'
end
