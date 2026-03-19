# frozen_string_literal: true

RSpec.describe WildSessionTelemetry::Configuration do
  subject(:config) { described_class.new }

  describe '#freeze!' do
    it 'freezes the configuration object' do
      config.freeze!
      expect(config).to be_frozen
    end
  end

  describe 'frozen configuration rejects writes' do
    before { config.freeze! }

    it 'raises FrozenError when setting store' do
      expect { config.store = :something }.to raise_error(FrozenError)
    end

    it 'raises FrozenError when setting retention_days' do
      expect { config.retention_days = 30 }.to raise_error(FrozenError)
    end

    it 'raises FrozenError when setting privacy_mode' do
      expect { config.privacy_mode = :relaxed }.to raise_error(FrozenError)
    end

    it 'raises FrozenError when setting max_storage_bytes' do
      expect { config.max_storage_bytes = 1024 }.to raise_error(FrozenError)
    end
  end

  describe 'readers work after freeze' do
    it 'returns default values after freeze' do
      config.freeze!
      expect(config.retention_days).to eq(90)
      expect(config.privacy_mode).to eq(:strict)
      expect(config.store).to be_nil
      expect(config.max_storage_bytes).to be_nil
    end

    it 'returns configured values after freeze' do
      config.retention_days = 30
      config.store = :memory
      config.freeze!
      expect(config.retention_days).to eq(30)
      expect(config.store).to eq(:memory)
    end
  end

  describe 'WildSessionTelemetry.configure auto-freezes' do
    it 'freezes configuration after configure block' do
      WildSessionTelemetry.configure { |c| c.retention_days = 60 }
      expect(WildSessionTelemetry.configuration).to be_frozen
    end

    it 'allows writes inside configure block' do
      expect do
        WildSessionTelemetry.configure { |c| c.retention_days = 60 }
      end.not_to raise_error
    end

    it 'rejects writes after configure block' do
      WildSessionTelemetry.configure { |c| c.retention_days = 60 }
      expect { WildSessionTelemetry.configuration.retention_days = 30 }.to raise_error(FrozenError)
    end
  end

  describe 'reset_configuration! unfreezes' do
    it 'creates a new unfrozen configuration' do
      WildSessionTelemetry.configure { |c| c.retention_days = 60 }
      WildSessionTelemetry.reset_configuration!
      expect(WildSessionTelemetry.configuration).not_to be_frozen
    end
  end
end
