require "rails_helper"

# Connecting a bank through Plaid (ADR 0018): the page that opens Plaid Link, what Link gives back, kept in the session, and the page after it where each account
# the person shared becomes a new Account or is left out. The checks themselves are in spec/services/connect_plaid_spec.rb. Plaid is replaced by PlaidFake
# (spec/support/plaid.rb), and Link itself runs only in a browser, so what it would send is posted here as the plaid-link controller posts it.
RSpec.describe "Connecting a bank through Plaid", type: :request do
  let(:budget) { create(:budget, currency: "CAD", user: create(:user, :plaid)) }

  around { |example| travel_to(Time.zone.local(2026, 11, 19, 12)) { example.run } }
  before do
    sign_in_as budget.user
    plaid.links("public-1", item_id: "item-1", institution_id: "ins_42", institution_name: "TD Canada Trust", accounts: [
      plaid.account("acc-1", "TD Every Day Chequing", mask: "4821", subtype: "checking"),
      plaid.account("acc-2", "TD U.S. Dollar Account", mask: "1100", subtype: "savings", currency: "USD")
    ])
  end

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  # What Link's onSuccess sends, as the plaid-link controller puts it in the form.
  def link_params(public_token: "public-1", accounts: nil)
    accounts ||= [ { id: "acc-1", name: "TD Every Day Chequing", mask: "4821", subtype: "checking" },
                   { id: "acc-2", name: "TD U.S. Dollar Account", mask: "1100", subtype: "savings" } ]
    { plaid_link: { public_token: public_token, institution_id: "ins_42", institution_name: "TD Canada Trust",
                    accounts: accounts.each_with_index.to_h { |account, index| [ index.to_s, account ] } } }
  end

  def finish_link(**options)
    post plaid_connection_path, params: link_params(**options)
  end

  def choose(rows)
    post plaid_choice_path, params: { plaid_choice: { accounts: rows } }
  end

  describe "Connect a bank on the Accounts page" do
    it "is offered beside Connect Splitwise and New account where Plaid is set up" do
      get accounts_path

      assert_select "a.btn[href='#{new_plaid_connection_path}']", text: "Connect a bank"
    end

    it "isn't offered, and its pages turn a request away, without Plaid's variables" do
      PlaidApi.client = PlaidFake.new(configured: false)

      get accounts_path
      assert_select "a[href='#{new_plaid_connection_path}']", count: 0

      [ -> { get new_plaid_connection_path }, -> { finish_link }, -> { get plaid_choice_path }, -> { choose({}) } ].each do |request|
        instance_exec(&request)
        expect(response).to redirect_to(accounts_path)
        expect(flash[:alert]).to eq("Connecting a bank isn't set up here.")
      end
      expect(plaid.link_tokens).to be_empty
    end
  end

  describe "GET /plaid/connection/new" do
    it "makes a link token for the budget, never an email, and opens Link with it from Plaid's own script" do
      get new_plaid_connection_path

      expect(response).to have_http_status(:ok)
      expect(plaid.link_tokens).to eq([ budget.id ])
      assert_select "title", text: "Connect a bank · Budgie"
      # Asked with `nonce: true`, which carries a nonce once a Content Security Policy has a nonce generator; Budgie has none yet.
      assert_select "head script[src='https://cdn.plaid.com/link/v2/stable/link-initialize.js']"
      assert_select "script[type=importmap]" do |importmap|
        expect(importmap.text).not_to include("cdn.plaid.com")
      end
      assert_select "head meta[name='turbo-cache-control'][content='no-cache']"
      assert_select "[data-controller='plaid-link'][data-plaid-link-token-value='link-sandbox-1']"
      assert_select "form[action='#{plaid_connection_path}'][method=post][data-plaid-link-target=form]"
      assert_select "button[data-action='plaid-link#open'][disabled]", text: "Continue to Plaid"
      expect(response.body).not_to include("turbo-refresh-method")
    end

    it "says Plaid's refusal on the Accounts page when it won't make a link token" do
      plaid.fails(:create_link_token, PlaidApi::Error.new("Plaid couldn't be reached."))

      get new_plaid_connection_path

      expect(response).to redirect_to(accounts_path)
      expect(flash[:alert]).to eq("Nothing was connected. Plaid couldn't be reached.")
    end
  end

  describe "POST /plaid/connection, what Link gives back" do
    it "is kept for the choice page, and exchanges nothing" do
      finish_link

      expect(response).to redirect_to(plaid_choice_path)
      expect(plaid.exchanges).to be_empty
      expect(Budget::BankConnection.count).to eq(0)
    end

    it "is refused when it isn't what Link sends" do
      post plaid_connection_path, params: { plaid_link: { public_token: "public-1" } }

      expect(response).to redirect_to(new_plaid_connection_path)
      expect(flash[:alert]).to eq("Plaid didn't say which accounts were shared, so nothing was connected. Try again.")
    end

    it "is refused when more accounts were shared than one connect can bring" do
      finish_link(accounts: (1..16).map { { id: "acc-#{it}", name: "Account #{it}", mask: it.to_s } })

      expect(response).to redirect_to(accounts_path)
      expect(flash[:alert]).to eq("Nothing was connected, since more than 15 accounts were shared. Connect again and share 15 or fewer.")
    end
  end

  describe "GET /plaid/connection/accounts, the choice page" do
    it "lists each shared account with Plaid's name, its mask and its kind, and what it becomes, starting as a new Account" do
      create(:budget_bank_transaction, account: create(:budget_account, budget: budget), date: Date.new(2026, 7, 4))
      finish_link

      get plaid_choice_path

      expect(response).to have_http_status(:ok)
      assert_select "h1", text: "Connect TD Canada Trust"
      assert_select "head meta[name='turbo-cache-control'][content='no-cache']"
      expect(visible_text).to include("You shared 2 accounts from TD Canada Trust. Choose what each one becomes.")
      expect(visible_text).to include("An account in another currency than your budget's (CAD) is left out, whatever it's set to here.")
      assert_select "li[data-controller='plaid-choice']", count: 2
      assert_select "li[data-controller='plaid-choice']", text: /TD Every Day Chequing\s+••4821\s+Checking/
      assert_select "select[name='plaid_choice[accounts][0][becomes]']" do
        assert_select "option[value=new][selected]", text: "A new Account"
        assert_select "option[value=leave]", text: "Leave out"
      end
      assert_select "input[name='plaid_choice[accounts][0][name]'][value='TD Every Day Chequing']"
      assert_select "input[type=date][name='plaid_choice[accounts][0][read_from]'][value='2026-07-04']"
      assert_select "input[name='plaid_choice[accounts][1][name]'][value='TD U.S. Dollar Account']"
      expect(visible_text).to include("Left out: its bank transactions aren't brought in.")
      assert_select "input[type=submit][value='Connect TD Canada Trust']"
      assert_select "button[formaction='#{plaid_choice_path}'][name=_method][value=delete]", text: "Cancel"
    end

    it "is back to the Accounts page when nothing is waiting to be connected" do
      get plaid_choice_path

      expect(response).to redirect_to(accounts_path)
      expect(flash[:alert]).to eq("Nothing is waiting to be connected. Connect a bank to choose its accounts.")
    end

    it "keeps nothing once 30 minutes have passed since Link finished" do
      finish_link
      travel 31.minutes

      get plaid_choice_path

      expect(response).to redirect_to(accounts_path)
      expect(flash[:alert]).to eq("Nothing was connected, since the accounts weren't chosen within 30 minutes. Connect again to choose them.")
      travel(-31.minutes)
      get plaid_choice_path
      expect(flash[:alert]).to eq("Nothing is waiting to be connected. Connect a bank to choose its accounts.")
    end

    it "is a 404 for what Link gave another budget" do
      finish_link
      other = create(:budget, user: create(:user, :plaid))
      allow(Current).to receive(:budget).and_return(other)

      get plaid_choice_path

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /plaid/connection/accounts, connecting" do
    before { finish_link }

    it "makes the connection and its new Accounts, leaves out one in another currency with a notice, and goes to the first new Account's page" do
      choose("0" => { becomes: "new", name: "Chequing", read_from: "2026-10-01" }, "1" => { becomes: "new", name: "US", read_from: "2026-10-01" })

      chequing = budget.accounts.find_by!(name: "Chequing")
      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:notice]).to eq("Connected TD Canada Trust. Its bank transactions arrive within the hour. TD U.S. Dollar Account was left out: it's in USD.")
      expect(chequing).to have_attributes(external_account_id: "acc-1", external_name: "TD Every Day Chequing", external_mask: "4821", files_with_rules: true, read_from: Date.new(2026, 10, 1))
      expect(budget.accounts.count).to eq(1)
      expect(plaid.exchanges).to eq([ "public-1" ])
    end

    it "forgets what Link gave back once it's connected" do
      choose("0" => { becomes: "new", name: "Chequing", read_from: "2026-10-01" }, "1" => { becomes: "leave" })

      get plaid_choice_path
      expect(response).to redirect_to(accounts_path)
    end

    it "says a mistake on the page, keeping the choices, and exchanges nothing" do
      create(:budget_account, budget: budget, name: "Chequing")

      choose("0" => { becomes: "new", name: "Chequing", read_from: "2026-10-01" }, "1" => { becomes: "leave", name: "Kept" })

      expect(response).to have_http_status(:unprocessable_content)
      expect(visible_text).to include("TD Every Day Chequing: Account name has already been taken")
      assert_select "input[name='plaid_choice[accounts][0][name]'][value=Chequing][aria-invalid=true]"
      assert_select "select[name='plaid_choice[accounts][1][becomes]'] option[value=leave][selected]"
      expect(plaid.exchanges).to be_empty

      choose("0" => { becomes: "new", name: "TD Chequing", read_from: "2026-10-01" }, "1" => { becomes: "leave" })
      expect(response).to redirect_to(account_path(budget.accounts.find_by!(name: "TD Chequing")))
    end

    it "asks for at least one account" do
      choose("0" => { becomes: "leave" }, "1" => { becomes: "leave" })

      expect(response).to have_http_status(:unprocessable_content)
      expect(visible_text).to include("Choose at least one account to connect.")
    end

    it "says a refusal on the Accounts page, and keeps nothing" do
      plaid.fails(:exchange_public_token, PlaidApi::Error.new(error_code: "ITEM_LIMIT", display_message: "No more banks can be connected."))

      choose("0" => { becomes: "new", name: "Chequing", read_from: "2026-10-01" }, "1" => { becomes: "leave" })

      expect(response).to redirect_to(accounts_path)
      expect(flash[:alert]).to eq("Nothing was connected. No more banks can be connected.")
      expect(Budget::BankConnection.count).to eq(0)
      get plaid_choice_path
      expect(response).to redirect_to(accounts_path)
    end

    it "is refused past the deadline without exchanging" do
      travel 31.minutes

      choose("0" => { becomes: "new", name: "Chequing", read_from: "2026-10-01" })

      expect(response).to redirect_to(accounts_path)
      expect(flash[:alert]).to start_with("Nothing was connected, since the accounts weren't chosen within 30 minutes.")
      expect(plaid.exchanges).to be_empty
    end

    it "refuses a bank that's already connected and points to its Account" do
      existing = create(:budget_bank_connection, :plaid, budget: budget, institution_id: "ins_42")
      create(:budget_account, :plaid, budget: budget, bank_connection: existing, name: "My TD", external_name: "TD Every Day Chequing", external_mask: "4821")

      choose("0" => { becomes: "new", name: "Chequing", read_from: "2026-10-01" })

      expect(response).to redirect_to(accounts_path)
      expect(flash[:alert]).to include("TD Canada Trust is already connected", "Choose accounts or Reconnect on My TD")
      expect(plaid.exchanges).to be_empty
    end
  end

  describe "DELETE /plaid/connection/accounts, Cancel" do
    it "keeps nothing and forgets what Link gave back" do
      finish_link

      delete plaid_choice_path

      expect(response).to redirect_to(accounts_path)
      expect(flash[:notice]).to eq("Nothing was connected.")
      expect(plaid.exchanges).to be_empty
      get plaid_choice_path
      expect(flash[:alert]).to eq("Nothing is waiting to be connected. Connect a bank to choose its accounts.")
    end
  end

  describe "the words" do
    it "never say Item or institution, nor a field's name, on any of the pages" do
      get new_plaid_connection_path
      words = [ visible_text ]
      finish_link
      get plaid_choice_path
      words << visible_text
      create(:budget_account, budget: budget, name: "Chequing")
      choose("0" => { becomes: "new", name: "Chequing", read_from: "2026-10-01" })
      words << visible_text

      retired = /\b(categor(y|ies)|income|inflow|outflow|budgeted|spending|expense|purchase|payment|transfer|move|reimbursement|repayment|wallet|(?<!bank\s)transaction|payee|payer)\b/i
      words.each do |text|
        expect(text).not_to match(/\b(item|institution)s?\b/i)
        expect(text).not_to match(/\w+_\w+/)
        expect(text).not_to match(retired)
      end
    end
  end

  describe "the public token" do
    it "is filtered from the logs, as the access token is" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

      expect(filter.filter("public_token" => "public-1", "access_token" => "access-1")).to eq("public_token" => "[FILTERED]", "access_token" => "[FILTERED]")
    end

    it "is never in a page" do
      finish_link
      get plaid_choice_path

      expect(response.body).not_to include("public-1")
    end
  end
end
