# frozen_string_literal: true

module WildSessionTelemetry
  module Privacy
    class Filter
      ALLOWED_TOP_LEVEL_KEYS = %i[event_type timestamp caller_id action outcome duration_ms metadata].freeze

      METADATA_ALLOWLISTS = {
        'action.completed' => %w[category operation phase denial_reason blast_radius_count confirmation_used].freeze,
        'gate.evaluated' => %w[gate_result capability_checked].freeze,
        'rate_limit.checked' => %w[rate_result current_count limit window_seconds].freeze
      }.freeze

      def filter(event)
        normalized = normalize(event)
        stripped = strip_top_level(normalized)
        filter_metadata(stripped)
      end

      private

      def normalize(event)
        event.transform_keys(&:to_sym)
      end

      def strip_top_level(event_hash)
        event_hash.slice(*ALLOWED_TOP_LEVEL_KEYS)
      end

      def filter_metadata(event_hash)
        metadata = event_hash[:metadata]
        return event_hash if metadata.nil? || !metadata.is_a?(Hash)

        event_type = event_hash[:event_type].to_s
        allowed_keys = METADATA_ALLOWLISTS.fetch(event_type, [])
        filtered = metadata.transform_keys(&:to_s).slice(*allowed_keys)
        event_hash.merge(metadata: filtered.transform_keys(&:to_sym))
      end
    end
  end
end
