require "rails_helper"

# Disconnecting a bank (ADR 0018): `/item/remove` first, so Plaid stops reading the bank and stops billing, and only then is the token forgotten. Plaid being unreachable, or
# refusing, changes nothing, and an Item that's already gone counts as removed. The Accounts stay synced, with their bank transactions, Filing rules and date to read from,
# and say so. Deleting a connection's last Account removes the Item too, and a connection that's already disconnected has nothing to remove. Plaid is replaced by PlaidFake.
RSpec.describe "Disconnecting a bank", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let(:connection) { create(:budget_bank_connection, :plaid, budget: budget, login_name: "TD Canada Trust", access_token: "its-token", needs_reconnect: false) }
  let!(:chequing) do
    create(:budget_account, :plaid, budget: budget, bank_connection: connection, name: "TD Chequing", external_name: "TD Every Day Chequing", external_mask: "4821",
      read_from: Date.new(2026, 10, 1))
  end
  let!(:savings) { create(:budget_account, :plaid, budget: budget, bank_connection: connection, name: "TD Savings", external_name: "TD ePremium Savings", external_mask: "1100") }

  before { sign_in_as budget.user }

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  def confirmations
    Nokogiri::HTML(response.body).css("[data-turbo-confirm]").map { it["data-turbo-confirm"] }
  end

  describe "the button" do
    it "is Disconnect TD, in the panel of each of the connection's Accounts, and asks naming every Account and the Trial" do
      [ chequing, savings ].each do |account|
        get account_path(account)

        assert_select "form[action='#{account_connection_path(account)}'] button", text: "Disconnect TD"
        expect(confirmations).to include("Disconnect TD Canada Trust? TD Chequing and TD Savings stop syncing and keep their bank transactions. " \
          "Connecting TD Canada Trust again later counts as a new connection on Plaid's Trial.")
      end
    end

    it "names the one Account, or a list of them, as they are" do
      savings.destroy!
      get account_path(chequing)
      expect(confirmations).to include("Disconnect TD Canada Trust? TD Chequing stops syncing and keeps its bank transactions. " \
        "Connecting TD Canada Trust again later counts as a new connection on Plaid's Trial.")

      create(:budget_account, :plaid, budget: budget, bank_connection: connection, name: "TD Visa")
      create(:budget_account, :plaid, budget: budget, bank_connection: connection, name: "TD Gone", unshared_at: Time.current)
      get account_path(chequing)
      expect(confirmations).to include(a_string_matching(/\ADisconnect TD Canada Trust\? TD Chequing and TD Visa stop syncing and keep their bank transactions\./))
    end

    it "is offered when the bank stopped accepting the connection too" do
      connection.needs_reconnect!

      get account_path(chequing)

      assert_select "form[action='#{account_connection_path(chequing)}'] button", text: "Disconnect TD"
    end

    it "isn't offered where Plaid isn't set up" do
      PlaidApi.client = PlaidFake.new(configured: false)

      get account_path(chequing)

      assert_select "button", text: "Disconnect TD", count: 0
    end
  end

  describe "pressing it" do
    it "removes the Item with the connection's token, forgets it, and keeps every Account with its bank transactions, Filing rules and date to read from" do
      transaction = create(:budget_bank_transaction, account: chequing, description: "LOBLAWS")
      rule = create(:budget_filing_rule, budget: budget, account: chequing, text: "loblaws")
      connection.update_columns(sync_cursor: "cursor-4", needs_reconnect: true)

      delete account_connection_path(chequing)

      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:notice]).to eq("Disconnected from TD Canada Trust.")
      expect(plaid.removals).to eq([ "its-token" ])
      expect(connection.reload).to be_disconnected
      expect(connection).not_to be_needs_reconnect
      expect(connection.sync_cursor).to eq("cursor-4")
      expect(Budget::Account.where(id: [ chequing.id, savings.id ])).to all(be_synced)
      expect(chequing.reload.read_from).to eq(Date.new(2026, 10, 1))
      expect(transaction.reload.account).to eq(chequing)
      expect(rule.reload.account).to eq(chequing)
    end

    [ PlaidFake.item_not_found, PlaidFake.invalid_access_token ].each do |error|
      it "counts #{error.error_code} as already removed, and forgets the token" do
        plaid.fails(:remove_item, error)

        delete account_connection_path(chequing)

        expect(flash[:notice]).to eq("Disconnected from TD Canada Trust.")
        expect(connection.reload).to be_disconnected
      end
    end

    it "is refused with nothing changed when Plaid can't be reached, so it can be tried again" do
      plaid.fails_once(:remove_item, PlaidFake.unreachable)

      delete account_connection_path(chequing)

      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:alert]).to eq("Plaid couldn't be reached, so TD Canada Trust wasn't disconnected and nothing was changed. Try again later.")
      expect(connection.reload).to be_connected

      delete account_connection_path(chequing)

      expect(flash[:notice]).to eq("Disconnected from TD Canada Trust.")
      expect(connection.reload).to be_disconnected
    end

    it "is refused with nothing changed for any other error of Plaid's, without repeating what Plaid said" do
      plaid.fails(:remove_item, PlaidApi::Error.new(error_code: "INTERNAL_SERVER_ERROR", status: 500))

      delete account_connection_path(chequing)

      expect(flash[:alert]).to eq("Plaid refused it (INTERNAL_SERVER_ERROR), so TD Canada Trust wasn't disconnected and nothing was changed. Try again later.")
      expect(connection.reload).to be_connected
    end

    it "is refused where Plaid isn't set up, without asking it" do
      PlaidApi.client = PlaidFake.new(configured: false)

      delete account_connection_path(chequing)

      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:alert]).to eq("Connecting a bank isn't set up here.")
      expect(connection.reload).to be_connected
    end

    it "is refused for a connection that's already disconnected, without asking Plaid" do
      connection.disconnect!

      delete account_connection_path(chequing)

      expect(flash[:alert]).to eq("TD Canada Trust isn't connected any more, so nothing was changed.")
      expect(plaid.removals).to be_empty
    end

    it "is a 404 for another user's Account, and one that isn't synced, and removes nothing" do
      delete account_connection_path(create(:budget_account, :plaid))
      expect(response).to have_http_status(:not_found)
      delete account_connection_path(create(:budget_account, budget: budget))
      expect(response).to have_http_status(:not_found)

      expect(plaid.removals).to be_empty
    end

    it "leaves Splitwise's Disconnect as it was, without calling Plaid" do
      splitwise = create(:budget_account, :synced, budget: budget)

      delete account_connection_path(splitwise)

      expect(flash[:notice]).to eq("Disconnected from Splitwise.")
      expect(splitwise.bank_connection.reload).to be_disconnected
      expect(plaid.removals).to be_empty
    end

    it "still doesn't make a bank's Account take Splitwise's Reconnect" do
      post account_connection_path(chequing)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "afterwards" do
    before do
      create(:budget_bank_transaction, account: chequing)
      connection.disconnect!
    end

    it "says on the Accounts list that each Account was synced from the bank, which was disconnected" do
      get accounts_path

      expect(visible_text).to include("TD Chequing Was synced from TD Canada Trust, which was disconnected. 1 bank transaction")
      expect(visible_text).to include("TD Savings Was synced from TD Canada Trust, which was disconnected. No bank transactions yet.")
      assert_select ".badge", text: "Needs reconnecting", count: 0
    end

    it "says it in each Account's panel, with no actions, and the Account still takes no Import" do
      get account_path(chequing)

      expect(visible_text).to include("Was synced from TD Canada Trust, which was disconnected.")
      expect(visible_text).to include("TD Savings")
      assert_select "main a.link[href='#{account_path(savings)}']", text: "TD Savings"
      assert_select "main a[href='#{new_account_import_path(chequing)}']", count: 0
      assert_select "button", text: /Sync|Disconnect/, count: 0
      assert_select "a", text: /Reconnect|Choose accounts/, count: 0
      assert_select "main [role=status]", count: 0
    end

    it "keeps the date to read from, which can still be changed" do
      get account_path(chequing)

      assert_select "details summary", text: /Date to read from\s+Bank transactions dated from Oct 1, 2026/
    end

    it "doesn't say a de-selected Account can share again, since there's nothing to choose accounts on" do
      savings.update!(unshared_at: Time.current)

      get account_path(savings)

      expect(visible_text).to include("Was synced from TD Canada Trust, which was disconnected.")
      expect(visible_text).not_to include("Choose accounts")
    end

    it "is skipped by the hourly job and isn't synced by hand" do
      expect(Budget::BankConnection.syncable).not_to include(connection)

      post account_connection_sync_path(chequing)

      expect(plaid.transaction_requests).to be_empty
    end
  end

  describe "deleting a connection's last Account" do
    it "removes the Item first, then deletes the Account and the connection" do
      delete account_path(savings)
      expect(plaid.removals).to be_empty

      delete account_path(chequing)

      expect(response).to redirect_to(accounts_path)
      expect(flash[:notice]).to eq("Account deleted.")
      expect(plaid.removals).to eq([ "its-token" ])
      expect(Budget::BankConnection.exists?(connection.id)).to be(false)
      expect(Budget::Account.exists?(chequing.id)).to be(false)
    end

    it "is refused with nothing changed when Plaid can't be reached" do
      savings.destroy!
      plaid.fails(:remove_item, PlaidFake.unreachable)

      delete account_path(chequing)

      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:alert]).to eq("Plaid couldn't be reached, so TD Chequing wasn't deleted and nothing was changed. Try again later.")
      expect(Budget::Account.exists?(chequing.id)).to be(true)
      expect(connection.reload).to be_connected
    end

    it "counts an Item that's already gone as removed" do
      savings.destroy!
      plaid.fails(:remove_item, PlaidFake.item_not_found)

      delete account_path(chequing)

      expect(flash[:notice]).to eq("Account deleted.")
      expect(Budget::BankConnection.exists?(connection.id)).to be(false)
    end

    it "makes no Plaid call for a connection that's already disconnected, and deletes both" do
      savings.destroy!
      connection.disconnect!

      delete account_path(chequing)

      expect(flash[:notice]).to eq("Account deleted.")
      expect(plaid.removals).to be_empty
      expect(Budget::BankConnection.exists?(connection.id)).to be(false)
    end

    it "doesn't remove the Item for an Account with bank transactions, which can't be deleted" do
      savings.destroy!
      create(:budget_bank_transaction, account: chequing)

      delete account_path(chequing)

      expect(flash[:alert]).to eq("This account can't be deleted because it has bank transactions.")
      expect(plaid.removals).to be_empty
      expect(connection.reload).to be_connected
    end

    it "doesn't remove the Item for an Account that isn't the last, which leaves its bank account unmapped" do
      delete account_path(savings)

      expect(plaid.removals).to be_empty
      expect(connection.reload).to be_connected
    end

    it "asks, saying the connection goes with it and that Budgie stops having access to the bank" do
      savings.destroy!

      get edit_account_path(chequing)

      expect(confirmations).to include("Delete the TD Chequing account? Its connection to TD Canada Trust is removed with it, and Budgie stops having access to TD Canada Trust.")
    end

    it "asks without the access, for a connection that's already disconnected" do
      savings.destroy!
      connection.disconnect!

      get edit_account_path(chequing)

      expect(confirmations).to include("Delete the TD Chequing account? Its connection to TD Canada Trust is removed with it.")
    end
  end
end
