# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe WildSessionTelemetry::Store::RetentionManager do
  let(:tmpdir) { Dir.mktmpdir('retention_manager_spec') }
  let(:store_path) { File.join(tmpdir, 'events.jsonl') }
  let(:store) { WildSessionTelemetry::Store::JsonLinesStore.new(path: store_path) }

  # The clock is pinned one day after new_envelope. These fixtures use fixed
  # dates, so a manager reading the wall clock would eventually treat
  # new_envelope as expired too (it did, from 2026-06-17 on).
  let(:now) { Time.utc(2026, 3, 20) }
  let(:clock) { -> { now } }

  # old_envelope has a received_at that is ~109 days before `now`,
  # well outside a 90-day retention window.
  let(:old_envelope) do
    WildSessionTelemetry::Schema::EventEnvelope.new(
      event_type: 'action.completed',
      timestamp: '2025-12-01T00:00:00.000Z',
      caller_id: 'test',
      action: 'old_action',
      outcome: 'success',
      received_at: '2025-12-01T00:00:00.000Z'
    )
  end

  let(:new_envelope) do
    WildSessionTelemetry::Schema::EventEnvelope.new(
      event_type: 'action.completed',
      timestamp: '2026-03-19T00:00:00.000Z',
      caller_id: 'test',
      action: 'new_action',
      outcome: 'success',
      received_at: '2026-03-19T00:00:00.000Z'
    )
  end

  after { FileUtils.remove_entry(tmpdir) }

  describe '#purge_expired' do
    context 'with a retention window of 90 days' do
      let(:manager) { described_class.new(store: store, retention_days: 90, clock: clock) }

      before do
        store.append(old_envelope)
        store.append(new_envelope)
      end

      it 'removes events older than the retention window' do
        manager.purge_expired
        expect(store.count).to eq(1)
      end

      it 'keeps events within the retention window' do
        manager.purge_expired
        remaining = store.recent.first
        expect(remaining.action).to eq('new_action')
      end

      it 'returns the count of removed events' do
        expect(manager.purge_expired).to eq(1)
      end
    end

    context 'when all events are within the retention window' do
      let(:manager) { described_class.new(store: store, retention_days: 90, clock: clock) }

      before { store.append(new_envelope) }

      it 'returns 0' do
        expect(manager.purge_expired).to eq(0)
      end
    end

    context 'when events sit exactly on the retention boundary' do
      let(:manager) { described_class.new(store: store, retention_days: 90, clock: clock) }
      let(:cutoff) { now - (90 * 86_400) }

      def envelope_received_at(time, action)
        WildSessionTelemetry::Schema::EventEnvelope.new(
          event_type: 'action.completed',
          timestamp: time.iso8601(3),
          caller_id: 'test',
          action: action,
          outcome: 'success',
          received_at: time.iso8601(3)
        )
      end

      before do
        store.append(envelope_received_at(cutoff - 0.001, 'one_ms_too_old'))
        store.append(envelope_received_at(cutoff, 'exactly_at_cutoff'))
        store.append(envelope_received_at(cutoff + 0.001, 'one_ms_inside'))
      end

      it 'purges only events strictly older than the cutoff' do
        expect(manager.purge_expired).to eq(1)
        expect(store.recent.map(&:action)).to contain_exactly('exactly_at_cutoff', 'one_ms_inside')
      end
    end

    context 'with the default clock' do
      it 'reads the wall clock, so production behavior is unchanged' do
        manager = described_class.new(store: store, retention_days: 90)
        store.append(old_envelope)
        expect(manager.purge_expired).to eq(1)
      end
    end

    context 'for a non-JsonLinesStore' do
      let(:memory_store) { WildSessionTelemetry::Store::MemoryStore.new }
      let(:manager) { described_class.new(store: memory_store, retention_days: 90) }

      it 'returns 0 without raising' do
        expect(manager.purge_expired).to eq(0)
      end
    end

    context 'when the file does not exist' do
      let(:manager) { described_class.new(store: store, retention_days: 90, clock: clock) }

      it 'returns 0' do
        expect(manager.purge_expired).to eq(0)
      end
    end

    context 'with a very short retention window (1 day)' do
      let(:manager) { described_class.new(store: store, retention_days: 1) }
      # Use a dynamic timestamp to ensure freshness regardless of test run time
      let(:fresh_envelope) do
        WildSessionTelemetry::Schema::EventEnvelope.new(
          event_type: 'action.completed',
          timestamp: Time.now.utc.iso8601(3),
          caller_id: 'test',
          action: 'fresh_action',
          outcome: 'success',
          received_at: Time.now.utc.iso8601(3)
        )
      end

      before do
        store.append(old_envelope)
        store.append(fresh_envelope)
      end

      it 'removes events older than one day' do
        manager.purge_expired
        expect(store.count).to eq(1)
      end
    end
  end

  describe '#purge_oversized' do
    context 'when max_size_bytes is nil' do
      let(:manager) { described_class.new(store: store, max_size_bytes: nil) }

      before { store.append(new_envelope) }

      it 'returns 0' do
        expect(manager.purge_oversized).to eq(0)
      end
    end

    context 'for a non-JsonLinesStore' do
      let(:memory_store) { WildSessionTelemetry::Store::MemoryStore.new }
      let(:manager) { described_class.new(store: memory_store, max_size_bytes: 1) }

      it 'returns 0 without raising' do
        expect(manager.purge_oversized).to eq(0)
      end
    end

    context 'when store is within the size limit' do
      let(:manager) { described_class.new(store: store, max_size_bytes: 1_000_000) }

      before { store.append(new_envelope) }

      it 'returns 0' do
        expect(manager.purge_oversized).to eq(0)
      end
    end

    context 'when store exceeds the size limit' do
      let(:manager) { described_class.new(store: store, max_size_bytes: 1) }

      before do
        store.append(old_envelope)
        store.append(new_envelope)
      end

      it 'removes oldest events until within the limit' do
        manager.purge_oversized
        expect(store.count).to eq(0)
      end

      it 'returns the count of removed events' do
        expect(manager.purge_oversized).to be > 0
      end

      it 'does not retain the oldest events after purging' do
        manager.purge_oversized
        actions = store.recent.map(&:action)
        expect(actions).not_to include('old_action')
      end
    end
  end

  describe '#purge_all' do
    context 'with both expired and oversized conditions' do
      let(:manager) { described_class.new(store: store, retention_days: 90, max_size_bytes: nil, clock: clock) }

      before do
        store.append(old_envelope)
        store.append(new_envelope)
      end

      it 'runs both purges and returns the total removed count' do
        total = manager.purge_all
        expect(total).to eq(1)
      end

      it 'removes expired events' do
        manager.purge_all
        expect(store.count).to eq(1)
      end
    end
  end
end
