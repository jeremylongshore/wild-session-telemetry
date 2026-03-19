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
        h = normalize(event)
        h = strip_top_level(h)
        h = filter_metadata(h)
        h
      end

      private

      def normalize(event)
        event.transform_keys(&:to_sym)
      end

      def strip_top_level(h)
        h.select { |key, _| ALLOWED_TOP_LEVEL_KEYS.include?(key) }
      end

      def filter_metadata(h)
        metadata = h[:metadata]
        return h if metadata.nil? || !metadata.is_a?(Hash)

        event_type = h[:event_type].to_s
        allowed_keys = METADATA_ALLOWLISTS.fetch(event_type, [])
        filtered = metadata.transform_keys(&:to_s).select { |key, _| allowed_keys.include?(key) }
        h.merge(metadata: filtered.transform_keys(&:to_sym))
      end
    end
  end
end
