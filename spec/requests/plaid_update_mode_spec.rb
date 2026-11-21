require "rails_helper"

# A bank's Reconnect and Choose accounts (ADR 0018), both Plaid Link's update mode, which keeps the Item and its account ids: a page that opens Link with an update-mode
# link token, and where Link says it finished. Reconnect clears needs-reconnect once Plaid answers `/accounts/get`; Choose accounts goes on to the choice page for the
# selected accounts that aren't Accounts yet, or saves straight away when there are none. The saving itself is in spec/services/choose_plaid_accounts_spec.rb. Plaid is
# replaced by PlaidFake (spec/support/plaid.rb), and Link runs only in a browser, so what it would send is posted here as the plaid-link controller posts it.
RSpec.describe "A bank's Reconnect and Choose accounts", type: :request do
  let(:budget) { create(:budget, currency: "CAD", user: create(:user, :plaid)) }
  let(:connection) { create(:budget_bank_connection, :plaid, budget: budget, login_name: "TD Canada Trust", access_token: "its-token", sync_cursor: "cursor-4") }
  let!(:chequing) do
    create(:budget_account, :plaid, budget: budget, bank_connection: connection, name: "TD Chequing", external_account_id: "acc-1",
      external_name: "TD Every Day Chequing", external_mask: "4821")
  end
  let!(:savings) do
    create(:budget_account, :plaid, budget: budget, bank_connection: connection, name: "TD Savings", external_account_id: "acc-2",
      external_name: "TD ePremium Savings", external_mask: "1100")
  end

  around { |example| travel_to(Time.zone.local(2026, 11, 19, 12)) { example.run } }
  before do
    sign_in_as budget.user
    plaid.item("its-token", accounts: [
      plaid.account("acc-1", "TD Every Day Chequing", mask: "4821"),
      plaid.account("acc-2", "TD ePremium Savings", mask: "1100", subtype: "savings"),
      plaid.account("acc-3", "TD Visa Infinite", mask: "7000", subtype: "credit card", type: "credit"),
      plaid.account("acc-4", "TD U.S. Dollar Account", mask: "2200", subtype: "savings", currency: "USD")
    ])
  end

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  # Each account as Link names it: its name, mask and kind.
  def shared(id)
    { "acc-1" => [ "TD Every Day Chequing", "4821", "checking" ], "acc-2" => [ "TD ePremium Savings", "1100", "savings" ],
      "acc-3" => [ "TD Visa Infinite", "7000", "credit card" ], "acc-4" => [ "TD U.S. Dollar Account", "2200", "savings" ] }.fetch(id)
  end

  # What Link's onSuccess sends in update mode with account selection: the whole selection, and nothing else.
  def finish_choosing(*ids, account: chequing)
    accounts = ids.each_with_index.to_h do |id, index|
      name, mask, subtype = shared(id)
      [ index.to_s, { id: id, name: name, mask: mask, subtype: subtype } ]
    end
    post account_connection_selection_path(account), params: { plaid_link: { accounts: accounts } }
  end

  describe "Reconnect" do
    it "opens Link in update mode on the connection, with no account selection, from a page that's never cached" do
      get new_account_connection_reconnect_path(chequing)

      expect(response).to have_http_status(:ok)
      expect(plaid.update_link_tokens).to eq([ { access_token: "its-token", client_user_id: budget.id, account_selection: false } ])
      expect(plaid.link_tokens).to be_empty
      assert_select "title", text: "Reconnect TD Canada Trust · Budgie"
      assert_select "main h1", text: "Reconnect TD Canada Trust"
      assert_select "head script[src='https://cdn.plaid.com/link/v2/stable/link-initialize.js']"
      assert_select "head meta[name='turbo-cache-control'][content='no-cache']"
      assert_select "[data-controller='plaid-link'][data-plaid-link-token-value='link-sandbox-update-1'][data-plaid-link-mode-value='reconnect']"
      assert_select "form[action='#{account_connection_reconnect_path(chequing)}'][method=post][data-plaid-link-target=form]"
      assert_select "button[data-action='plaid-link#open'][disabled]", text: "Continue to Plaid"
      assert_select "a.btn[href='#{account_path(chequing)}']", text: "Cancel"
      expect(response.body).not_to include("turbo-refresh-method")
    end

    it "says Plaid's refusal on the Account's page when it won't make a link token" do
      plaid.fails(:create_update_link_token, PlaidApi::Error.new("Plaid couldn't be reached."))

      get new_account_connection_reconnect_path(chequing)

      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:alert]).to eq("TD Canada Trust wasn't reconnected. Plaid couldn't be reached.")
    end

    it "clears needs-reconnect once Plaid answers with the connection's token, exchanging nothing, and says so" do
      connection.needs_reconnect!

      post account_connection_reconnect_path(savings)

      expect(response).to redirect_to(account_path(savings))
      expect(flash[:notice]).to eq("Reconnected TD Canada Trust.")
      expect(plaid.account_requests).to eq([ "its-token" ])
      expect(plaid.exchanges).to be_empty
      expect(connection.reload).to be_connected
      expect(connection.access_token).to eq("its-token")
    end

    it "refreshes a connection that works too" do
      post account_connection_reconnect_path(chequing)

      expect(flash[:notice]).to eq("Reconnected TD Canada Trust.")
      expect(connection.reload).to be_connected
    end

    it "leaves it needing reconnecting while Plaid still won't answer" do
      connection.needs_reconnect!
      plaid.fails(:accounts, PlaidApi::Error.new(error_code: "ITEM_LOGIN_REQUIRED"))

      post account_connection_reconnect_path(chequing)

      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:alert]).to eq("TD Canada Trust still needs reconnecting.")
      expect(connection.reload).to be_needs_reconnect
    end

    it "says Plaid's refusal for a connection that works when Plaid can't be asked, and leaves it as it was" do
      plaid.fails(:accounts, PlaidApi::Error.new("Plaid couldn't be reached."))

      post account_connection_reconnect_path(chequing)

      expect(flash[:alert]).to eq("TD Canada Trust wasn't reconnected. Plaid couldn't be reached.")
      expect(connection.reload).to be_connected
    end

    it "holds the connection's lock while it asks Plaid and clears needs-reconnect" do
      expect_any_instance_of(Budget::BankConnection).to receive(:with_lock).and_call_original

      post account_connection_reconnect_path(chequing)
    end

    it "marks a connection that seemed to work as needing reconnecting when Plaid says so" do
      plaid.fails(:accounts, PlaidApi::Error.new(error_code: "ITEM_LOGIN_REQUIRED"))

      post account_connection_reconnect_path(chequing)

      expect(flash[:alert]).to eq("TD Canada Trust still needs reconnecting.")
      expect(connection.reload).to be_needs_reconnect
    end
  end

  describe "Choose accounts" do
    it "opens Link in update mode with account selection" do
      get new_account_connection_selection_path(savings)

      expect(response).to have_http_status(:ok)
      expect(plaid.update_link_tokens).to eq([ { access_token: "its-token", client_user_id: budget.id, account_selection: true } ])
      assert_select "main h1", text: "Choose accounts on TD Canada Trust"
      assert_select "head meta[name='turbo-cache-control'][content='no-cache']"
      assert_select "[data-controller='plaid-link'][data-plaid-link-mode-value='choose']"
      assert_select "form[action='#{account_connection_selection_path(savings)}'][method=post]"
      assert_select "a.btn[href='#{account_path(savings)}']", text: "Cancel"
    end

    it "leads to the choice page for the selected accounts that aren't Accounts yet, with one in another currency left out", :aggregate_failures do
      finish_choosing("acc-1", "acc-3", "acc-4")

      expect(response).to redirect_to(plaid_choice_path)
      follow_redirect!

      assert_select "title", text: "Choose accounts on TD Canada Trust · Budgie"
      assert_select "main h1", text: "Choose accounts on TD Canada Trust"
      expect(visible_text).to include("TD Canada Trust now shares 2 accounts that aren't Accounts yet.")
      expect(visible_text).to include("TD Savings isn't shared any more, so once you save, nothing new comes in. Its bank transactions stay as they are.")
      expect(visible_text).not_to include("TD Every Day Chequing")
      assert_select "select[name='plaid_choice[accounts][1][becomes]']:not([disabled]) option", text: "A new Account"
      assert_select "input[name='plaid_choice[accounts][1][name]'][value='TD Visa Infinite']"
      assert_select "select[name='plaid_choice[accounts][2][becomes]'][disabled][aria-describedby]" do
        assert_select "option", count: 1, text: "Left out"
      end
      expect(visible_text).to include("It's in USD and your budget is in CAD, so it can only be left out.")
      assert_select "input[type=submit][value='Save']"
      assert_select "button[formaction='#{plaid_choice_path}'][value=delete]", text: "Cancel"
    end

    it "saves on the choice page, back on the Account it started from, and resets the cursor" do
      finish_choosing("acc-1", "acc-2", "acc-3", "acc-4")

      post plaid_choice_path, params: { plaid_choice: { accounts: { "2" => { becomes: "new", name: "Visa", read_from: "2026-10-01" }, "3" => { becomes: "new" } } } }

      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:notice]).to eq("Added Visa from TD Canada Trust. Its bank transactions arrive within the hour.")
      expect(budget.accounts.find_by!(name: "Visa")).to have_attributes(external_account_id: "acc-3", read_from: Date.new(2026, 10, 1))
      expect(budget.accounts.where(external_account_id: "acc-4")).to be_empty
      expect(connection.reload.sync_cursor).to be_nil

      get plaid_choice_path
      expect(response).to redirect_to(accounts_path)
    end

    it "says on the page what's wrong with a choice" do
      finish_choosing("acc-1", "acc-2", "acc-3")

      post plaid_choice_path, params: { plaid_choice: { accounts: { "2" => { becomes: "new", name: "TD Savings" } } } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(visible_text).to include("TD Visa Infinite: Account name has already been taken")
      expect(budget.accounts.count).to eq(2)
    end

    it "saves straight away, without the choice page, when every selected account is already an Account" do
      finish_choosing("acc-1")

      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:notice]).to eq("TD Savings is no longer shared, so nothing new comes in.")
      expect(savings.reload).to be_unshared
      expect(connection.reload.sync_cursor).to eq("cursor-4")

      get plaid_choice_path
      expect(flash[:alert]).to eq("Nothing is waiting to be connected. Connect a bank to choose its accounts.")
    end

    it "shares an Account again when it's selected again" do
      savings.update!(unshared_at: 1.day.ago)

      finish_choosing("acc-1", "acc-2", account: savings)

      expect(response).to redirect_to(account_path(savings))
      expect(flash[:notice]).to eq("TD Savings is shared again.")
      expect(savings.reload).not_to be_unshared
      expect(connection.reload.sync_cursor).to be_nil
    end

    it "keeps nothing on Cancel, back on the Account" do
      finish_choosing("acc-1", "acc-3")

      delete plaid_choice_path

      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:notice]).to eq("Nothing was changed.")
      expect(savings.reload).not_to be_unshared
      expect(budget.accounts.count).to eq(2)
    end

    it "keeps nothing once 30 minutes have passed since Link finished" do
      finish_choosing("acc-1", "acc-3")
      travel 31.minutes

      get plaid_choice_path

      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:alert]).to eq("Nothing was changed, since the accounts weren't chosen within 30 minutes. Choose accounts again.")
    end

    it "says Plaid's refusal when it can't say what the accounts are" do
      finish_choosing("acc-1", "acc-3")
      plaid.fails(:accounts, PlaidApi::Error.new(display_message: "The bank isn't answering."))

      get plaid_choice_path

      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:alert]).to eq("Nothing was changed. The bank isn't answering.")
    end

    it "asks again when Link named no account" do
      post account_connection_selection_path(chequing), params: { plaid_link: { accounts: {} } }

      expect(response).to redirect_to(new_account_connection_selection_path(chequing))
      expect(flash[:alert]).to eq("Plaid didn't say which accounts are shared, so nothing was changed. Try again.")
    end

    it "says so, back on the Account, when the saved connection's token can't be read" do
      finish_choosing("acc-1", "acc-3")
      allow_any_instance_of(Budget::BankConnection).to receive(:access_token).and_raise(ActiveRecord::Encryption::Errors::Decryption)

      get plaid_choice_path

      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:alert]).to eq("Nothing was changed, since Budgie can't read the saved connection to TD Canada Trust.")
    end

    it "is a 404 for another budget's pending choice" do
      finish_choosing("acc-1", "acc-3")
      sign_in_as create(:budget, user: create(:user, :plaid)).user

      get plaid_choice_path

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "who can ask" do
    let(:requests) do
      [ ->(account) { get new_account_connection_reconnect_path(account) }, ->(account) { post account_connection_reconnect_path(account) },
        ->(account) { get new_account_connection_selection_path(account) }, ->(account) { finish_choosing("acc-1", account: account) } ]
    end

    it "is a 404 for another user's Account, a CSV Account and a Splitwise Account" do
      [ create(:budget_account, :plaid), create(:budget_account, budget: budget), create(:budget_account, :synced, budget: budget) ].each do |account|
        requests.each do |request|
          request.call(account)
          expect(response).to have_http_status(:not_found)
        end
      end
      expect(plaid.update_link_tokens + plaid.account_requests).to be_empty
    end

    it "is turned away where Plaid isn't set up" do
      PlaidApi.client = PlaidFake.new(configured: false)

      requests.each do |request|
        request.call(chequing)
        expect(response).to redirect_to(account_path(chequing))
        expect(flash[:alert]).to eq("Connecting a bank isn't set up here.")
      end
    end

    it "is turned away for a connection that was disconnected" do
      connection.disconnect!

      requests.each do |request|
        request.call(chequing)
        expect(response).to redirect_to(account_path(chequing))
        expect(flash[:alert]).to eq("TD Canada Trust isn't connected any more, so nothing was changed.")
      end
    end
  end
end
