# frozen_string_literal: true

require 'json'
require 'time'

module WildSessionTelemetry
  module Export
    class Exporter
      def initialize(store:, record_builder: nil, aggregator: nil)
        @store = store
        @record_builder = record_builder || RecordBuilder.new
        @aggregator = aggregator
      end

      def export(since: nil, before: nil, event_type: nil, caller_id: nil)
        events = fetch_events(since: since, before: before, event_type: event_type)
        events = events.select { |e| e.caller_id == caller_id } if caller_id

        event_records = events.map { |e| @record_builder.event_record(e) }
        aggregation_records = compute_aggregations(events)
        header = build_header(since: since, before: before, event_count: event_records.size,
                              aggregation_records: aggregation_records)

        lines = [JSON.generate(header)]
        event_records.each { |r| lines << JSON.generate(r) }
        aggregation_records.each { |r| lines << JSON.generate(r) }
        lines
      end

      private

      def fetch_events(since:, before:, event_type:)
        @store.query(event_type: event_type, since: since, before: before)
      end

      def compute_aggregations(events)
        return [] unless @aggregator

        [
          *@aggregator.session_summaries(events).map { |s| @record_builder.session_summary_record(s) },
          *@aggregator.tool_utilization(events).map { |u| @record_builder.tool_utilization_record(u) },
          *@aggregator.outcome_distributions(events).map { |d| @record_builder.outcome_distribution_record(d) },
          *@aggregator.latency_stats(events).map { |l| @record_builder.latency_stats_record(l) }
        ]
      end

      def build_header(since:, before:, event_count:, aggregation_records: [])
        counts = { events: event_count }
        aggregation_records.each do |r|
          type = r[:record_type]
          counts[type] = (counts[type] || 0) + 1
        end
        @record_builder.header(
          schema_version: '1.0.0',
          exported_at: Time.now.utc.iso8601(3),
          time_range: { start: since, end: before },
          record_counts: counts
        )
      end
    end
  end
end
