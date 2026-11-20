require "rails_helper"

# The Accounts a bank connected through Plaid syncs (ADR 0018): they're on the Accounts list saying where they're from, each one's page has a panel for its connection
# in place of Import, with Sync TD now, they take no CSV Import from any way in, and what reconnects or disconnects Splitwise doesn't reach them yet.
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

    it "offers Sync TD now, named for the bank, and none of Splitwise's other actions, which come later for a bank" do
      get account_path(chequing)

      assert_select "form[action='#{account_connection_sync_path(chequing)}'] button[data-turbo-submits-with]", text: "Sync TD now"
      expect(visible_text).not_to include("Sync now", "Reconnect", "Disconnect", "expense")
    end

    it "offers no Sync TD now where Plaid isn't set up, or once the bank stopped accepting the connection, which it says" do
      PlaidApi.client = PlaidFake.new(configured: false)
      get account_path(chequing)
      assert_select "button", text: "Sync TD now", count: 0

      PlaidApi.client = PlaidFake.new
      connection.needs_reconnect!
      get account_path(chequing)
      assert_select "button", text: "Sync TD now", count: 0
      assert_select "[role=status].alert-warning", text: "TD Canada Trust stopped accepting the connection, so this Account isn't syncing."
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

  describe "Sync TD now" do
    def adds(*transactions)
      plaid.adds(connection.access_token, *transactions)
    end

    it "brings the posted transactions of every Account of the connection in, says what it did, and says when it last synced", :aggregate_failures do
      adds plaid.transaction("tx-1", account: chequing.external_account_id, amount: "82.45", date: "2026-10-03", description: "LOBLAWS #1234"),
        plaid.transaction("tx-2", account: savings.external_account_id, amount: "-100.00", date: "2026-10-04", description: "TRANSFER IN"),
        plaid.transaction("tx-3", account: chequing.external_account_id, currency: "USD")

      post account_connection_sync_path(chequing)

      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:notice]).to eq("Synced from TD Canada Trust: 2 new. 1 skipped.")
      expect(chequing.bank_transactions.pluck(:description, :amount)).to eq([ [ "LOBLAWS #1234", BigDecimal("-82.45") ] ])
      expect(savings.bank_transactions.pluck(:amount)).to eq([ BigDecimal("100.00") ])

      follow_redirect!
      expect(visible_text).to include("Last synced less than a minute ago.", "LOBLAWS #1234")
    end

    it "links Review them to the To review state of every Account when Filing rules filed some, since they file in each of the connection's Accounts" do
      create(:budget_filing_rule, budget: budget, text: "loblaws")
      adds plaid.transaction("tx-1", account: chequing.external_account_id, description: "LOBLAWS #1234")

      post account_connection_sync_path(savings)
      follow_redirect!

      assert_select "[role=status]", text: /Synced from TD Canada Trust: 1 new\. Filing rules filed 1 of them\. Review them/
      assert_select "[role=status] a[href='#{bank_transactions_path(filter: { state: "to_review" })}']", text: "Review them"
    end

    it "says the bank stopped accepting the connection, and changes nothing, when Plaid says it needs signing in again" do
      adds plaid.transaction("tx-1", account: chequing.external_account_id)
      plaid.fails_once(:transactions_sync, PlaidApi::Error.new(error_code: "ITEM_LOGIN_REQUIRED", error_type: "ITEM_ERROR", status: 400))

      post account_connection_sync_path(chequing)

      expect(flash[:alert]).to eq("TD Canada Trust stopped accepting the connection, so nothing was synced.")
      expect(connection.reload).to be_needs_reconnect
      expect(chequing.bank_transactions).to be_empty
    end

    it "is turned away where Plaid isn't set up" do
      PlaidApi.client = PlaidFake.new(configured: false)

      post account_connection_sync_path(chequing)

      expect(response).to redirect_to(accounts_path)
      expect(flash[:alert]).to eq("Plaid isn't set up here, so it can't be synced.")
    end

    it "is synced by the hourly job too" do
      adds plaid.transaction("tx-1", account: chequing.external_account_id)

      SyncBankConnectionsJob.perform_now

      expect(chequing.bank_transactions.count).to eq(1)
    end
  end

  describe "a bank transaction the bank removed" do
    let!(:removed) { create(:budget_bank_transaction, :removed, account: chequing, description: "LOBLAWS #1234", date: Date.new(2026, 10, 3)) }
    let!(:filed) { create(:budget_bank_transaction, :removed, :filed, account: savings, description: "COSTCO #99", date: Date.new(2026, 10, 4)) }

    def badges(description)
      css_select("main ul.list li").find { it.text.include?(description) }.css(".badge").map { it.text.squish }
    end

    it "says the bank removed it, beside Un-file when it was filed, on the Bank transactions page and on its Account's page", :aggregate_failures do
      get bank_transactions_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31" })

      expect(badges("LOBLAWS #1234")).to eq([ "Removed by TD Canada Trust" ])
      expect(badges("COSTCO #99")).to eq([ "Filed", "Removed by TD Canada Trust" ])
      expect(visible_text).to include("Un-file it, or keep its records.")

      get account_path(chequing)

      expect(badges("LOBLAWS #1234")).to eq([ "Removed by TD Canada Trust" ])
    end

    it "leaves the Unfiled state, and filing it is refused in the bank's words" do
      get bank_transactions_path(filter: { state: "unfiled" })
      expect(visible_text).not_to include("LOBLAWS #1234")

      envelope = create(:budget_envelope, budget: budget)
      post bank_transaction_filing_path(removed),
        params: { filing: { records: { "0" => { kind: "spend", envelope_id: envelope.id, description: "Loblaws", date: "2026-10-03", amount: "10", notes: "" } } } }

      expect(flash[:alert]).to eq("This bank transaction was removed by TD Canada Trust, so it can't be filed.")
    end
  end

  describe "what's Splitwise's alone, until a later ticket" do
    it "is a 404: Reconnect and Disconnect, which forgets no token without Plaid being told" do
      post account_connection_path(chequing)
      expect(response).to have_http_status(:not_found)
      delete account_connection_path(chequing)
      expect(response).to have_http_status(:not_found)

      expect(connection.reload).to be_connected
    end
  end
end
