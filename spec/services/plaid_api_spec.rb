require "rails_helper"

# PlaidApi.client is the one seam: specs replace it (spec/support/plaid.rb), and the real one is built from the environment. Whether Budgie can connect a bank at all
# depends on the client id, secret and environment, and on the keys the token is kept under.
RSpec.describe PlaidApi do
  # The keys are put back after the examples that take them away.
  around do |example|
    primary_key = ActiveRecord::Encryption.config.primary_key
    key_derivation_salt = ActiveRecord::Encryption.config.key_derivation_salt
    example.run
  ensure
    ActiveRecord::Encryption.config.primary_key = primary_key
    ActiveRecord::Encryption.config.key_derivation_salt = key_derivation_salt
  end

  def with_env(values)
    original = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| ENV[key] = value }
  end

  describe ".client" do
    it "is the one that's been given, which is how specs replace it" do
      fake = PlaidFake.new
      described_class.client = fake

      expect(described_class.client).to be(fake)
    end

    it "is the real client, made from the environment, when none has been given" do
      described_class.client = nil

      with_env("PLAID_CLIENT_ID" => "an-id", "PLAID_SECRET" => "a-secret", "PLAID_ENV" => "sandbox") do
        expect(described_class.client).to be_a(PlaidApi::Client).and be_configured
      end
    end

    it "is the real client, and not configured, without them" do
      described_class.client = nil

      with_env("PLAID_CLIENT_ID" => nil, "PLAID_SECRET" => nil, "PLAID_ENV" => nil) do
        expect(described_class.client).not_to be_configured
      end
    end
  end

  describe ".configured?" do
    it "is true when the client is configured and the token's keys are set" do
      expect(described_class).to be_configured
    end

    it "is false without the client's variables, so that Connect a bank isn't offered" do
      described_class.client = PlaidFake.new(configured: false)

      expect(described_class).not_to be_configured
    end

    it "is false when the keys the token is encrypted with aren't set, whatever the client says" do
      ActiveRecord::Encryption.config.primary_key = nil
      expect(described_class).not_to be_configured

      ActiveRecord::Encryption.config.primary_key = "a-key"
      ActiveRecord::Encryption.config.key_derivation_salt = nil
      expect(described_class).not_to be_configured
    end
  end

  describe ".available_to?" do
    let(:budget) { create(:budget, user: create(:user, :plaid)) }

    it "is true where Plaid is set up and the budget's person has it turned on" do
      expect(described_class.available_to?(budget)).to be(true)
    end

    it "is false for a person who doesn't have it turned on, as if Plaid weren't set up for them" do
      expect(described_class.available_to?(create(:budget))).to be(false)
    end

    it "is false where Plaid isn't set up, whoever has it turned on" do
      described_class.client = PlaidFake.new(configured: false)

      expect(described_class.available_to?(budget)).to be(false)
    end

    it "is false with no budget, as before setup" do
      expect(described_class.available_to?(nil)).to be(false)
    end
  end

  describe PlaidApi::Error do
    it "says Plaid's message for a person, or its code, or that it couldn't be done" do
      expect(described_class.new(error_code: "X", display_message: "Try later.").message).to eq("Try later.")
      expect(described_class.new(error_code: "ITEM_LIMIT").message).to eq("Plaid refused it (ITEM_LIMIT).")
      expect(described_class.new.message).to eq("Plaid couldn't do it.")
      expect(described_class.new("Plaid couldn't be reached.").message).to eq("Plaid couldn't be reached.")
    end
  end
end
