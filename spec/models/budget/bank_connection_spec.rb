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
    it "is one that's supported: Splitwise, and a bank through Plaid" do
      expect(described_class::PROVIDERS).to eq([ "splitwise", "plaid" ])
      expect(build(:budget_bank_connection, provider: "splitwise")).to be_valid
      expect(build(:budget_bank_connection, :plaid)).to be_valid
    end

    it "is refused when it isn't one" do
      connection = build(:budget_bank_connection, provider: "flinks")

      expect(connection).not_to be_valid
      expect(connection.errors[:provider]).to eq([ "isn't supported" ])
    end

    it "has a name to show" do
      expect(build(:budget_bank_connection, provider: "splitwise").provider_name).to eq("Splitwise")
      expect(build(:budget_bank_connection, :plaid).provider_name).to eq("Plaid")
    end

    it "is refused by the database too" do
      expect { build(:budget_bank_connection, provider: "flinks").save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid, /budget_bank_connections_provider_known/)
    end
  end

  describe "a bank connected through Plaid" do
    subject(:connection) { build(:budget_bank_connection, :plaid, login_id: "item-1", login_name: "TD Canada Trust", institution_id: "ins_42") }

    it "is one Item: its login is the Item's id and its name the bank's" do
      expect(connection).to be_valid
      expect(connection).to be_plaid
      expect(connection).not_to be_splitwise
    end

    it "is named for the bank, where a Splitwise connection is named for Splitwise" do
      expect(connection.name).to eq("TD Canada Trust")
      expect(build(:budget_bank_connection, login_name: "Robert G.").name).to eq("Splitwise")
    end

    it "needs the bank's Plaid id, which the database checks too, and a Splitwise connection has none" do
      connection.institution_id = " "

      expect(connection).not_to be_valid
      expect(connection.errors[:institution_id]).to eq([ "can't be blank" ])
      expect { connection.save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid, /budget_bank_connections_plaid_has_institution/)
      expect(build(:budget_bank_connection, institution_id: nil)).to be_valid
    end

    it "isn't the one account, so it can have several Accounts" do
      expect(connection.login_is_the_account?).to be(false)

      connection.save!
      chequing = create(:budget_account, :plaid, budget: connection.budget, bank_connection: connection, external_account_id: "acc-1")
      savings = create(:budget_account, :plaid, budget: connection.budget, bank_connection: connection, external_account_id: "acc-2")

      expect(connection.accounts).to contain_exactly(chequing, savings)
    end

    it "keeps its token encrypted, as a Splitwise connection's is" do
      connection.access_token = "access-sandbox-secret"
      connection.save!

      stored = described_class.connection.select_value("SELECT access_token FROM budget_bank_connections WHERE id = #{connection.id}")
      expect(stored).not_to include("access-sandbox-secret")
      expect(connection.reload.access_token).to eq("access-sandbox-secret")
    end

    it "is synced through Plaid, where Plaid is set up and its budget's person has it turned on" do
      connection.save!
      allow(SyncPlaid).to receive(:call).and_return(:synced)

      expect(connection.sync).to eq(:synced)
      expect(connection).not_to be_provider_available
      connection.budget.user.enable_feature!(:plaid)
      expect(connection).to be_provider_available
      PlaidApi.client = PlaidFake.new(configured: false)
      expect(connection).not_to be_provider_available
    end

    it "is a Splitwise connection's to sync where Splitwise is set up, whoever has Plaid turned on" do
      splitwise_connection = create(:budget_bank_connection)

      expect(splitwise_connection).to be_provider_available
      Splitwise.client = SplitwiseFake.new(configured: false)
      expect(splitwise_connection).not_to be_provider_available
    end

    it "has a short name, the bank's first word, for a button that names it" do
      expect(connection.short_name).to eq("TD")
      expect(described_class.short_name("Tartan-Dominion Bank of Canada")).to eq("Tartan")
      expect(described_class.short_name("…")).to eq("…")
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

  it "has no date to read from, which is each of its Accounts' own" do
    expect(described_class.column_names).not_to include("read_from")
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

  describe "removing a bank's Item at Plaid" do
    let(:connection) { create(:budget_bank_connection, :plaid, access_token: "its-token", needs_reconnect: true, budget: create(:budget, user: create(:user, :plaid))) }

    it "asks Plaid to remove it with the connection's token, then forgets the token and that it needed reconnecting, keeping the rest" do
      connection.update_columns(sync_cursor: "cursor-4")

      connection.disconnect_from_plaid!

      expect(plaid.removals).to eq([ "its-token" ])
      expect(connection.reload).to be_disconnected
      expect(connection).not_to be_needs_reconnect
      expect(connection.sync_cursor).to eq("cursor-4")
    end

    [ PlaidFake.item_not_found, PlaidFake.invalid_access_token ].each do |error|
      it "counts #{error.error_code} as already removed, and forgets the token" do
        plaid.fails(:remove_item, error)

        expect { connection.disconnect_from_plaid! }.not_to raise_error

        expect(connection.reload).to be_disconnected
      end
    end

    it "raises Plaid's error, and keeps the token, when Plaid can't be reached" do
      plaid.fails(:remove_item, PlaidFake.unreachable)

      expect { connection.disconnect_from_plaid! }.to raise_error(PlaidApi::Error, "Plaid couldn't be reached.")

      expect(connection.reload).not_to be_disconnected
      expect(connection).to be_needs_reconnect
    end

    it "raises any other error of Plaid's, and keeps the token" do
      plaid.fails(:remove_item, PlaidApi::Error.new(error_code: "INTERNAL_SERVER_ERROR", status: 500))

      expect { connection.disconnect_from_plaid! }.to raise_error(PlaidApi::Error, "Plaid refused it (INTERNAL_SERVER_ERROR).")

      expect(connection.reload).not_to be_disconnected
    end

    it "refuses, without asking Plaid, where Plaid isn't set up" do
      PlaidApi.client = PlaidFake.new(configured: false)

      expect { connection.disconnect_from_plaid! }.to raise_error(PlaidApi::Error, "Plaid isn't set up here.")

      expect(connection.reload).not_to be_disconnected
    end

    it "refuses, without asking Plaid, for a person who doesn't have it turned on, as if Plaid weren't set up" do
      connection.budget.user.disable_feature!(:plaid)

      expect { connection.disconnect_from_plaid! }.to raise_error(PlaidApi::Error, "Plaid isn't set up here.")

      expect(plaid.removals).to be_empty
      expect(connection.reload).not_to be_disconnected
    end

    it "doesn't ask Plaid again for one that's already disconnected" do
      connection.disconnect_from_plaid!
      plaid.removals.clear

      connection.reload.disconnect_from_plaid!

      expect(plaid.removals).to be_empty
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

    it "keeps everything else when it's disconnected: the login, the marker and its Account, with its date to read from" do
      account = create(:budget_account, :synced)
      connection = account.bank_connection
      connection.update!(sync_cursor: "2026-10-05T12:00:00Z", synced_at: Time.zone.local(2026, 10, 5, 12))

      connection.disconnect!

      expect(connection.reload).to have_attributes(login_name: "Robert G.", sync_cursor: "2026-10-05T12:00:00Z")
      expect(connection.synced_at).to be_present
      expect(connection.accounts).to eq([ account ])
      expect(account.reload.read_from).to eq(Date.new(2026, 10, 1))
    end

    it "is connected again, and no longer needs reconnecting, with the new token and the login's name as Splitwise has it now" do
      connection = create(:budget_bank_connection, access_token: "old-token", login_name: "Robert G.", needs_reconnect: true)

      connection.reconnect!(access_token: "new-token", login_name: "Rob G.")

      expect(connection.reload).to be_connected
      expect(connection).to have_attributes(access_token: "new-token", login_name: "Rob G.", needs_reconnect: false)
    end

    it "is encrypted at rest after it's replaced too, which is written without going through the usual save" do
      connection = create(:budget_bank_connection, access_token: "old-token")

      connection.reconnect!(access_token: "replacement-secret-token", login_name: "Robert G.")

      stored = described_class.find(connection.id).access_token_before_type_cast
      expect(stored).to be_present
      expect(stored).not_to include("replacement-secret-token")
    end

    it "is connected again after it was disconnected" do
      connection = create(:budget_bank_connection)
      connection.disconnect!

      connection.reconnect!(access_token: "another-token", login_name: connection.login_name)

      expect(connection.reload).to be_connected
    end
  end

  describe "the sync cursor, which is where the last sync got to" do
    it "is plain text the provider's sync owns, with no meaning here" do
      expect(described_class.new).not_to respond_to(:sync_marker)
    end

    it "is forgotten by #forget_sync_cursor!, so the next sync starts again" do
      connection = create(:budget_bank_connection, sync_cursor: "2026-10-05T12:00:00Z")

      connection.forget_sync_cursor!

      expect(connection.reload.sync_cursor).to be_nil
    end

    it "is kept when anything else changes" do
      connection = create(:budget_bank_connection, sync_cursor: "2026-10-05T12:00:00Z")

      connection.update!(login_name: "Rob G.")

      expect(connection.reload.sync_cursor).to eq("2026-10-05T12:00:00Z")
    end
  end

  describe ".syncable" do
    it "is the connections that have a token that isn't known to have stopped working" do
      working = create(:budget_bank_connection)
      create(:budget_bank_connection, needs_reconnect: true)
      create(:budget_bank_connection).disconnect!

      expect(described_class.syncable).to contain_exactly(working)
    end
  end

  describe "#needs_reconnect!" do
    it "says the token has stopped working, which a sync finds out, without reading it" do
      connection = create(:budget_bank_connection)

      connection.needs_reconnect!

      expect(connection.reload).to be_needs_reconnect
      expect(connection).not_to be_connected
      expect(described_class.syncable).to be_empty
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

    it "can't be removed at Plaid, which needs the token, so Disconnect raises and keeps it" do
      stuck = unreadable(create(:budget_bank_connection, :plaid, budget: create(:budget, user: create(:user, :plaid))))

      expect { stuck.disconnect_from_plaid! }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)

      expect(described_class.find(stuck.id)).not_to be_disconnected
      expect(plaid.removals).to be_empty
    end

    it "can still be disconnected, since forgetting a token needs nothing of it" do
      stuck = unreadable(create(:budget_bank_connection))

      stuck.disconnect!

      expect(described_class.find(stuck.id)).to be_disconnected
    end

    it "can still have its sync cursor forgotten, which never reads the token either" do
      stuck = unreadable(create(:budget_bank_connection, sync_cursor: "2026-10-05T12:00:00Z"))

      stuck.forget_sync_cursor!

      expect(described_class.find(stuck.id).sync_cursor).to be_nil
    end

    it "can still be reconnected, which is how it's put right" do
      stuck = unreadable(create(:budget_bank_connection, needs_reconnect: true))

      stuck.reconnect!(access_token: "a-token-under-the-new-key", login_name: "Robert G.")

      fresh = described_class.find(stuck.id)
      expect(fresh).to be_connected
      expect(fresh.access_token).to eq("a-token-under-the-new-key")
    end
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
