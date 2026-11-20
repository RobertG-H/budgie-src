require "rails_helper"

# The Accounts a bank connected through Plaid syncs (ADR 0018), before their sync is built: they're on the Accounts list saying where they're from, each one's page
# has a panel for its connection in place of Import, they take no CSV Import from any way in, and nothing that syncs or disconnects Splitwise reaches them yet.
RSpec.describe "Accounts synced from a bank through Plaid", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let(:connection) { create(:budget_bank_connection, :plaid, budget: budget, login_name: "TD Canada Trust") }
  let!(:chequing) do
    create(:budget_account, :plaid, budget: budget, bank_connection: connection, name: "TD Chequing", external_name: "TD Every Day Chequing", external_mask: "4821",
      read_from: Date.new(2026, 10, 1))
  end
  let!(:savings) { create(:budget_account, :plaid, budget: budget, bank_connection: connection, name: "TD Savings", external_name: "TD ePremium Savings", external_mask: "1100") }
  let!(:csv_format) { create(:budget_csv_format, budget: budget, name: "Plain") }

  before { sign_in_as budget.user }

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  def uploaded
    Rack::Test::UploadedFile.new(StringIO.new("2026-10-01,Paycheck,2800.00\n"), "text/csv", original_filename: "october.csv")
  end

  describe "the Accounts list" do
    it "stays flat, and each row says which bank it's synced from" do
      get accounts_path

      expect(visible_text).to include("TD Chequing Synced from TD Canada Trust. No bank transactions yet.")
      expect(visible_text).to include("TD Savings Synced from TD Canada Trust. No bank transactions yet.")
    end
  end

  describe "an Account's page" do
    it "has no Import, and a panel named for the bank saying which account it is, what else the connection syncs, and that it hasn't synced" do
      get account_path(chequing)

      expect(response).to have_http_status(:ok)
      assert_select "main a[href='#{new_account_import_path(chequing)}']", count: 0
      assert_select "main h2", text: "TD Canada Trust"
      expect(visible_text).to include("Synced from TD Canada Trust, TD Every Day Chequing ••4821.")
      expect(visible_text).to include("The same connection syncs TD Savings, so what's done here is done to it too.")
      assert_select "main a.link[href='#{account_path(savings)}']", text: "TD Savings"
      expect(visible_text).to include("Not synced yet.")
      expect(visible_text).to include("No bank transactions yet. Bank transactions from TD Canada Trust appear here once they're synced.")
    end

    it "offers none of Splitwise's actions, which come later for a bank" do
      get account_path(chequing)

      expect(visible_text).not_to include("Sync now", "Reconnect", "Disconnect", "expense")
    end

    it "has the date to read from, under a closed details, in bank transactions" do
      get account_path(chequing)

      assert_select "details:not([open]) summary", text: /Date to read from\s+Bank transactions dated from Oct 1, 2026/
      assert_select "label[for='account_read_from']", text: "Read bank transactions dated from"
      expect(visible_text).to include("TD Canada Trust bank transactions dated before this are never read.")
    end

    it "changes the date, which clears the connection's cursor" do
      connection.update_columns(sync_cursor: "cursor-1")

      patch account_connection_path(chequing), params: { account: { read_from: "2026-09-01" } }

      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:notice]).to eq("Now reading bank transactions dated from Sep 1, 2026. The next sync reads them again.")
      expect(chequing.reload.read_from).to eq(Date.new(2026, 9, 1))
      expect(connection.reload.sync_cursor).to be_nil
    end

    it "is a 404 for another user's" do
      other = create(:budget_account, :plaid)

      get account_path(other)

      expect(response).to have_http_status(:not_found)
    end

    it "asks whether the connection goes with it only for its last Account" do
      get edit_account_path(chequing)
      expect(response.body).not_to include("Its connection to TD Canada Trust is removed with it.")

      savings.destroy!
      get edit_account_path(chequing)
      expect(response.body).to include("Its connection to TD Canada Trust is removed with it.")
    end

    it "deletes the connection with its last Account, without asking Plaid" do
      delete account_path(chequing)
      delete account_path(savings)

      expect(Budget::BankConnection.exists?(connection.id)).to be(false)
      expect(plaid.removals).to be_empty
    end
  end

  describe "importing into one" do
    it "isn't offered, and isn't done from a crafted request, which says it's synced from the bank" do
      get new_account_import_path(chequing)
      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:alert]).to eq("TD Chequing is synced from TD Canada Trust, so it takes no Import.")

      expect { post account_imports_path(chequing), params: { import: { csv_format_id: csv_format.id, file: uploaded } } }
        .not_to change { [ Budget::Import.count, Budget::BankTransaction.count ] }
      expect { post imports_path, params: { import: { csv_format_id: csv_format.id, account_id: chequing.id, file: uploaded } } }
        .not_to change { [ Budget::Import.count, Budget::BankTransaction.count ] }
    end

    it "leaves it out of the whole form's Account select" do
      create(:budget_account, budget: budget, name: "Visa")

      get new_import_path

      assert_select "select[name='import[account_id]'] option", text: "TD Chequing", count: 0
      assert_select "select[name='import[account_id]'] option", text: "Visa"
    end
  end

  describe "what's Splitwise's alone, until a later ticket" do
    it "is a 404: Sync now, Reconnect and Disconnect, which forgets no token without Plaid being told" do
      post account_connection_sync_path(chequing)
      expect(response).to have_http_status(:not_found)
      post account_connection_path(chequing)
      expect(response).to have_http_status(:not_found)
      delete account_connection_path(chequing)
      expect(response).to have_http_status(:not_found)

      expect(connection.reload).to be_connected
    end

    it "is a 404 for Sync now even where Splitwise isn't set up, rather than Splitwise's own refusal" do
      Splitwise.client = SplitwiseFake.new(configured: false)

      post account_connection_sync_path(chequing)

      expect(response).to have_http_status(:not_found)
    end

    it "isn't synced by the hourly job" do
      allow(SyncSplitwise).to receive(:call).and_call_original

      SyncBankConnectionsJob.perform_now

      expect(SyncSplitwise).not_to have_received(:call)
    end
  end
end
