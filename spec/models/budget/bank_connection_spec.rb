require "rails_helper"

# What a budget's Accounts are synced through, such as a Splitwise sign-in. It belongs to its budget, holds the provider's login and the
# token that reads it, and says whether that token is still good. A Splitwise connection has one Account.
RSpec.describe Budget::BankConnection, type: :model do
  subject(:connection) { build(:budget_bank_connection) }

  it { is_expected.to belong_to(:budget) }
  it { is_expected.to have_many(:accounts).class_name("Budget::Account").dependent(:restrict_with_error) }

  it "uses the budget_bank_connections table, and is named without the Budget prefix in routes and params" do
    expect(described_class.table_name).to eq("budget_bank_connections")
    expect(described_class.model_name).to have_attributes(route_key: "bank_connections", param_key: "bank_connection")
  end

  it "belongs to its budget and never to a user" do
    expect(described_class.column_names).to include("budget_id")
    expect(described_class.column_names).not_to include("user_id")
  end

  it "has no sync marker and has never synced, until a sync says so" do
    expect(create(:budget_bank_connection)).to have_attributes(sync_cursor: nil, synced_at: nil)
  end

  describe "provider" do
    it "is one that's supported, and Splitwise is the first" do
      expect(described_class::PROVIDERS).to eq([ "splitwise" ])
      expect(build(:budget_bank_connection, provider: "splitwise")).to be_valid
    end

    it "is refused when it isn't one" do
      connection = build(:budget_bank_connection, provider: "plaid")

      expect(connection).not_to be_valid
      expect(connection.errors[:provider]).to eq([ "isn't supported" ])
    end

    it "has a name to show" do
      expect(build(:budget_bank_connection, provider: "splitwise").provider_name).to eq("Splitwise")
    end

    it "is refused by the database too" do
      expect { build(:budget_bank_connection, provider: "plaid").save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid, /budget_bank_connections_provider_known/)
    end
  end

  describe "the provider's login" do
    it { is_expected.to validate_presence_of(:login_id) }
    it { is_expected.to validate_presence_of(:login_name) }

    it "is one connection for a budget, provider and login" do
      budget = create(:budget)
      create(:budget_bank_connection, budget: budget, login_id: "4321")

      duplicate = build(:budget_bank_connection, budget: budget, login_id: "4321")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:login_id]).to eq([ "is already connected" ])
    end

    it "is refused as a second connection by the unique index when the validation is skipped" do
      budget = create(:budget)
      create(:budget_bank_connection, budget: budget, login_id: "4321")

      expect { build(:budget_bank_connection, budget: budget, login_id: "4321").save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "may be connected by another budget too: it's one connection for each budget, not one for the login" do
      create(:budget_bank_connection, login_id: "4321")

      expect(build(:budget_bank_connection, login_id: "4321")).to be_valid
    end
  end

  describe "the date to read from" do
    it { is_expected.to validate_presence_of(:read_from) }

    it "can be today, or the day after, which is today for someone ahead of Eastern time" do
      travel_to Time.utc(2026, 10, 6, 16) do
        expect(build(:budget_bank_connection, read_from: Date.new(2026, 10, 6))).to be_valid
        expect(build(:budget_bank_connection, read_from: Date.new(2026, 10, 7))).to be_valid
      end
    end

    it "can't be more than a day after today, or before 1990" do
      travel_to Time.utc(2026, 10, 6, 16) do
        later = build(:budget_bank_connection, read_from: Date.new(2026, 10, 8))
        earlier = build(:budget_bank_connection, read_from: Date.new(1989, 12, 31))

        expect(later).not_to be_valid
        expect(later.errors[:read_from]).to eq([ "can't be in the future" ])
        expect(earlier).not_to be_valid
        expect(earlier.errors[:read_from]).to eq([ "can't be before 1990" ])
        expect(build(:budget_bank_connection, read_from: Date.new(1990, 1, 1))).to be_valid
      end
    end
  end

  describe "its token" do
    it "is encrypted at rest, and reads back as it was" do
      saved = create(:budget_bank_connection, access_token: "secret-splitwise-token")

      stored = saved.reload.access_token_before_type_cast
      expect(described_class.encrypted_attributes).to include(:access_token)
      expect(stored).to be_present
      expect(stored).not_to include("secret-splitwise-token")
      expect(saved.access_token).to eq("secret-splitwise-token")
    end

    it "is left out of what a record shows of itself" do
      saved = create(:budget_bank_connection, access_token: "secret-splitwise-token")

      expect(saved.inspect).not_to include("secret-splitwise-token")
      expect(saved.reload.inspect).not_to include("secret-splitwise-token")
    end

    it "is filtered from the logs, wherever it's a param" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

      expect(filter.filter(access_token: "secret", code: "an-authorization-code")).to eq(access_token: "[FILTERED]", code: "[FILTERED]")
    end
  end

  describe "its state" do
    it "is connected while there's a token, and it isn't known to have stopped working" do
      connection = build(:budget_bank_connection)

      expect(connection).to be_connected
      expect(connection).not_to be_disconnected
      expect(connection).not_to be_needs_reconnect
    end

    it "needs reconnecting once the token has stopped working, which only a sync finds out" do
      connection = create(:budget_bank_connection, needs_reconnect: true)

      expect(connection).not_to be_connected
      expect(connection).to be_needs_reconnect
      expect(connection).not_to be_disconnected
    end

    it "is disconnected once the token is forgotten" do
      connection = create(:budget_bank_connection)

      connection.disconnect!

      expect(connection.reload).to be_disconnected
      expect(connection).not_to be_connected
      expect(connection.access_token).to be_nil
    end

    it "forgets that it needed reconnecting when it's disconnected, since there's no token to have stopped working" do
      connection = create(:budget_bank_connection, needs_reconnect: true)

      connection.disconnect!

      expect(connection.reload).not_to be_needs_reconnect
    end

    it "can't need reconnecting without a token, which the database checks too" do
      expect { create(:budget_bank_connection, access_token: nil, needs_reconnect: true) }.to raise_error(ActiveRecord::StatementInvalid, /budget_bank_connections_needs_reconnect_has_token/)
    end

    it "keeps everything else when it's disconnected: the login, the date to read from, the marker and its Account" do
      account = create(:budget_account, :synced)
      connection = account.bank_connection
      connection.update!(sync_cursor: "2026-10-05T12:00:00Z", synced_at: Time.zone.local(2026, 10, 5, 12))

      connection.disconnect!

      expect(connection.reload).to have_attributes(login_name: "Robert G.", read_from: Date.new(2026, 10, 1), sync_cursor: "2026-10-05T12:00:00Z")
      expect(connection.synced_at).to be_present
      expect(connection.accounts).to eq([ account ])
    end

    it "is connected again, and no longer needs reconnecting, with the new token and the login's name as Splitwise has it now" do
      connection = create(:budget_bank_connection, access_token: "old-token", login_name: "Robert G.", needs_reconnect: true)

      connection.reconnect!(access_token: "new-token", login_name: "Rob G.")

      expect(connection.reload).to be_connected
      expect(connection).to have_attributes(access_token: "new-token", login_name: "Rob G.", needs_reconnect: false)
    end

    it "is connected again after it was disconnected" do
      connection = create(:budget_bank_connection)
      connection.disconnect!

      connection.reconnect!(access_token: "another-token", login_name: connection.login_name)

      expect(connection.reload).to be_connected
    end
  end

  describe "when the key its token was encrypted under has been lost" do
    # Ciphertext that no key can read, as a key that's been changed leaves.
    def unreadable(connection)
      garbage = { "p" => Base64.strict_encode64("not-the-payload"), "h" => { "iv" => Base64.strict_encode64("0123456789ab"), "at" => Base64.strict_encode64("0123456789abcdef") } }.to_json
      described_class.connection.execute(described_class.sanitize_sql_array([ "UPDATE budget_bank_connections SET access_token = ? WHERE id = ?", garbage, connection.id ]))
      described_class.find(connection.id)
    end

    it "can't be read, but still says it isn't disconnected without needing to" do
      stuck = unreadable(create(:budget_bank_connection))

      expect(stuck).not_to be_disconnected
      expect(stuck).to be_connected
      expect { stuck.access_token }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
    end

    it "can still be disconnected, since forgetting a token needs nothing of it" do
      stuck = unreadable(create(:budget_bank_connection))

      stuck.disconnect!

      expect(described_class.find(stuck.id)).to be_disconnected
    end

    it "can still be reconnected, which is how it's put right" do
      stuck = unreadable(create(:budget_bank_connection, needs_reconnect: true))

      stuck.reconnect!(access_token: "a-token-under-the-new-key", login_name: "Robert G.")

      fresh = described_class.find(stuck.id)
      expect(fresh).to be_connected
      expect(fresh.access_token).to eq("a-token-under-the-new-key")
    end
  end

  it "needs a name to reconnect with, as it did to be made" do
    connection = create(:budget_bank_connection)

    expect { connection.reconnect!(access_token: "t", login_name: " ") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  describe "its Accounts" do
    it "are its budget's, never another's" do
      connection = create(:budget_bank_connection)
      account = build(:budget_account, bank_connection: connection, external_account_id: connection.login_id)

      expect(account).not_to be_valid
      expect(account.errors[:bank_connection]).to eq([ "isn't one of this budget's" ])
    end

    it "can't be deleted from under it: the connection refuses while an Account has it" do
      account = create(:budget_account, :synced)

      expect(account.bank_connection.destroy).to be(false)
      expect(account.bank_connection.errors.full_messages).to eq([ "Cannot delete record because dependent accounts exist" ])
    end
  end
end
