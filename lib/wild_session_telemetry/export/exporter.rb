# frozen_string_literal: true

require 'json'
require 'time'

module WildSessionTelemetry
  module Export
    class Exporter
      def initialize(store:, record_builder: nil)
        @store = store
        @record_builder = record_builder || RecordBuilder.new
      end

      def export(since: nil, before: nil, event_type: nil, caller_id: nil)
        events = fetch_events(since: since, before: before, event_type: event_type)
        events = events.select { |e| e.caller_id == caller_id } if caller_id

        event_records = events.map { |e| @record_builder.event_record(e) }
        header = build_header(since: since, before: before, event_count: event_records.size)

        lines = [JSON.generate(header)]
        event_records.each { |r| lines << JSON.generate(r) }
        lines
      end

      private

      def fetch_events(since:, before:, event_type:)
        @store.query(event_type: event_type, since: since, before: before)
      end

      def build_header(since:, before:, event_count:)
        @record_builder.header(
          schema_version: '1.0.0',
          exported_at: Time.now.utc.iso8601(3),
          time_range: { start: since, end: before },
          record_counts: { events: event_count }
        )
      end
    end
  end
end
