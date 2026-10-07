require "rails_helper"

# Splitwise.client is the one seam: specs replace it (spec/support/splitwise.rb), and the real one is built from the environment. Whether Budgie can connect
# at all depends on the app's client id and secret and on the keys the token is kept under.
RSpec.describe Splitwise do
  # The keys are put back after the examples that take them away.
  around do |example|
    primary_key = ActiveRecord::Encryption.config.primary_key
    key_derivation_salt = ActiveRecord::Encryption.config.key_derivation_salt
    example.run
  ensure
    ActiveRecord::Encryption.config.primary_key = primary_key
    ActiveRecord::Encryption.config.key_derivation_salt = key_derivation_salt
  end

  describe ".client" do
    it "is the one that's been given, which is how specs replace it" do
      fake = SplitwiseFake.new
      described_class.client = fake

      expect(described_class.client).to be(fake)
    end

    it "is the real client, made from the environment's client id and secret, when none has been given" do
      described_class.client = nil

      with_env("SPLITWISE_CLIENT_ID" => "an-id", "SPLITWISE_CLIENT_SECRET" => "a-secret") do
        expect(described_class.client).to be_a(Splitwise::Client).and be_configured
      end
    end

    it "is the real client, and not configured, without them" do
      described_class.client = nil

      with_env("SPLITWISE_CLIENT_ID" => nil, "SPLITWISE_CLIENT_SECRET" => nil) do
        expect(described_class.client).to be_a(Splitwise::Client)
        expect(described_class.client).not_to be_configured
      end
    end
  end

  describe ".configured?" do
    it "is true when the client has its id and secret and the token's keys are set" do
      expect(described_class).to be_configured
    end

    it "is false without a client id or secret, so that Connect Splitwise isn't offered" do
      described_class.client = SplitwiseFake.new(configured: false)

      expect(described_class).not_to be_configured
    end

    it "is false when the keys the token is encrypted with aren't set, whatever the client says" do
      ActiveRecord::Encryption.config.primary_key = nil

      expect(described_class).not_to be_configured
    end

    it "is false without the key derivation salt either" do
      ActiveRecord::Encryption.config.key_derivation_salt = nil

      expect(described_class).not_to be_configured
    end
  end

  def with_env(values)
    original = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| ENV[key] = value }
  end
end
